#!/bin/bash

# 确保脚本以root权限运行
if [ "$EUID" -ne 0 ]; then 
    echo "请使用root权限运行此脚本"
    exit 1
fi

# 错误处理函数
error_exit() {
    echo "错误: $1" >&2
    exit 1
}

# 设置变量
APP_USER="tgbot"
APP_DIR="/opt/tgbot"
VENV_DIR="$APP_DIR/venv"
SERVICE_NAME="tgbot"
LOG_DIR="/var/log/$SERVICE_NAME"

# 检查必要的命令
command -v python3 >/dev/null 2>&1 || error_exit "需要python3但未安装"
command -v pip3 >/dev/null 2>&1 || error_exit "需要pip3但未安装"

# 创建目录
mkdir -p "$LOG_DIR" || error_exit "无法创建日志目录"
mkdir -p "$APP_DIR" || error_exit "无法创建应用目录"

# 更新系统并安装依赖
apt-get update || error_exit "apt-get update 失败"
apt-get install -y python3-venv python3-pip git supervisor || error_exit "依赖安装失败"

# 创建应用用户（如果不存在）
if ! id -u "$APP_USER" >/dev/null 2>&1; then
    useradd -r -s /bin/false "$APP_USER" || error_exit "创建用户失败"
fi

cd "$APP_DIR" || error_exit "无法进入应用目录"

# 创建并激活Python虚拟环境
python3 -m venv "$VENV_DIR" || error_exit "虚拟环境创建失败"
source "$VENV_DIR/bin/activate" || error_exit "虚拟环境激活失败"

# 创建requirements.txt，包含所有必要的依赖
cat > "$APP_DIR/requirements.txt" << EOF
python-telegram-bot==13.7
schedule==1.1.0
feedparser==6.0.10
python-dateutil==2.8.2
pytz==2021.3
requests==2.26.0
EOF

# 安装Python依赖
"$VENV_DIR/bin/pip" install -r requirements.txt || error_exit "依赖安装失败"

# 创建主程序
cat > "$APP_DIR/bot.py" << 'EOF'
#!/usr/bin/env python3
import logging
import time
from datetime import datetime
import threading
import schedule
import json
import os
from collections import OrderedDict, defaultdict
import feedparser
from telegram.ext import Updater, CommandHandler, MessageHandler, Filters
from functools import wraps
import sys
import shutil

# Basic config
TELEGRAM_TOKEN = 'xxxxxxx'# 替换为你的TelegramBOT TOKEN
CHAT_ID = '-xxxxxx' # 替换为你的Telegram群组 ID
BOT_DIR = '/var/log/tgbot'
KEYWORDS_FILE = os.path.join(BOT_DIR, 'keywords.json')
RSS_FILE = os.path.join(BOT_DIR, 'rss_feeds.json')
LOG_FILE = os.path.join(BOT_DIR, 'bot.log')
ADMIN_FILE = os.path.join(BOT_DIR, 'admins.json')
BACKUP_DIR = os.path.join(BOT_DIR, 'backups')

# 添加命令频率限制配置
RATE_LIMIT_WINDOW = 60  # 时间窗口(秒)
RATE_LIMIT_CALLS = 5    # 允许的最大请求次数
COMMAND_COOLDOWN = 3    # 命令冷却时间(秒)

# 默认配置
KEYWORDS = ['claw', '爪云', '阿爪', '啊爪', '爪爪云']  # 默认关键词
ADMIN_IDS = [wadawfwf]  # 默认管理员ID 替换为你的Telegram用户ID即可
DEFAULT_RSS_FEEDS = {
    'NodeSeek': 'https://rss.nodeseek.com',
    'V2EX': 'https://www.v2ex.com/index.xml',
}

OFFICIAL_ID = 'CLAWCLOUD-VPS'
CHECK_INTERVAL = 3
CACHE_DURATION = 24 * 3600  # 24小时的缓存时间

# 命令使用记录
command_history = defaultdict(list)
last_command_time = defaultdict(float)

# 确保必要的目录存在
def ensure_directories():
    """确保所有必要的目录存在"""
    try:
        for directory in [BOT_DIR, BACKUP_DIR]:
            if not os.path.exists(directory):
                os.makedirs(directory, mode=0o755)
                print(f"Created directory: {directory}")
    except Exception as e:
        print(f"Error creating directories: {str(e)}")
        sys.exit(1)

# 初始化目录
ensure_directories()

# Setup logging
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO,
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout)
    ]
)

logger = logging.getLogger(__name__)

class PersistentMessageCache:
    """持久化消息缓存类"""
    def __init__(self, cache_file):
        self.cache_file = cache_file
        self.cache = self.load_cache()

    def load_cache(self):
        """加载缓存"""
        try:
            if os.path.exists(self.cache_file):
                with open(self.cache_file, 'r') as f:
                    cache_data = json.load(f)
                    # 清理过期缓存
                    current_time = time.time()
                    cache_data = {k: v for k, v in cache_data.items() 
                                if current_time - v < CACHE_DURATION}
                    return cache_data
        except Exception as e:
            logger.error(f"加载缓存失败: {str(e)}")
        return {}

    def save_cache(self):
        """保存缓存"""
        try:
            with open(self.cache_file, 'w') as f:
                json.dump(self.cache, f)
        except Exception as e:
            logger.error(f"保存缓存失败: {str(e)}")

    def contains(self, key):
        """检查是否包含某个key"""
        return key in self.cache

    def add(self, key):
        """添加新key"""
        self.cache[key] = time.time()
        self.save_cache()

    def clear_expired(self):
        """清理过期缓存"""
        current_time = time.time()
        expired_keys = [k for k, v in self.cache.items() 
                       if current_time - v >= CACHE_DURATION]
        for k in expired_keys:
            del self.cache[k]
        if expired_keys:
            self.save_cache()

# 初始化消息缓存
message_cache = PersistentMessageCache(os.path.join(BOT_DIR, 'message_cache.json'))

def rate_limit(func):
    """命令频率限制装饰器"""
    @wraps(func)
    def wrapper(update, context, *args, **kwargs):
        user_id = update.effective_user.id
        current_time = time.time()
        
        # 检查命令冷却时间
        if current_time - last_command_time[user_id] < COMMAND_COOLDOWN:
            remaining = round(COMMAND_COOLDOWN - (current_time - last_command_time[user_id]), 1)
            update.message.reply_text(f"⚠️ 请等待 {remaining} 秒后再使用命令")
            return
        
        # 清理过期的命令历史
        command_history[user_id] = [t for t in command_history[user_id] 
                                  if current_time - t < RATE_LIMIT_WINDOW]
        
        # 检查是否超过频率限制
        if len(command_history[user_id]) >= RATE_LIMIT_CALLS:
            update.message.reply_text(f"⚠️ 命令使用过于频繁，请稍后再试")
            return
        
        # 记录本次命令使用
        command_history[user_id].append(current_time)
        last_command_time[user_id] = current_time
        
        # 记录命令使用日志
        log_command_usage(update)
        
        return func(update, context, *args, **kwargs)
    return wrapper

def log_command_usage(update):
    """记录命令使用情况"""
    user = update.effective_user
    command = update.message.text
    log_entry = {
        'timestamp': datetime.now().isoformat(),
        'user_id': user.id,
        'username': user.username,
        'command': command,
        'chat_id': update.effective_chat.id
    }
    
    try:
        log_file = os.path.join(BOT_DIR, 'command_log.jsonl')
        with open(log_file, 'a', encoding='utf-8') as f:
            f.write(json.dumps(log_entry, ensure_ascii=False) + '\n')
    except Exception as e:
        logger.error(f"记录命令日志失败: {str(e)}")

def load_admins():
    """从文件加载管理员ID列表"""
    try:
        if os.path.exists(ADMIN_FILE):
            with open(ADMIN_FILE, 'r') as f:
                return json.load(f)
        # 如果文件不存在，使用默认管理员列表并保存
        save_admins(ADMIN_IDS)
        return ADMIN_IDS
    except Exception as e:
        logger.error(f"加载管理员列表失败: {str(e)}")
        return ADMIN_IDS

def save_admins(admin_ids):
    """保存管理员ID列表到文件"""
    try:
        with open(ADMIN_FILE, 'w') as f:
            json.dump(admin_ids, f)
    except Exception as e:
        logger.error(f"保存管理员列表失败: {str(e)}")

def load_keywords():
    """从文件加载关键词列表"""
    try:
        if os.path.exists(KEYWORDS_FILE):
            with open(KEYWORDS_FILE, 'r', encoding='utf-8') as f:
                return json.load(f)
        return KEYWORDS
    except Exception as e:
        logger.error(f"加载关键词失败: {str(e)}")
        return KEYWORDS

def save_keywords(keywords):
    """保存关键词列表到文件"""
    try:
        with open(KEYWORDS_FILE, 'w', encoding='utf-8') as f:
            json.dump(keywords, f, ensure_ascii=False, indent=2)
    except Exception as e:
        logger.error(f"保存关键词失败: {str(e)}")
        raise

def load_rss_feeds():
    """从文件加载RSS源列表"""
    try:
        if os.path.exists(RSS_FILE):
            with open(RSS_FILE, 'r', encoding='utf-8') as f:
                return json.load(f)
        return DEFAULT_RSS_FEEDS
    except Exception as e:
        logger.error(f"加载RSS源失败: {str(e)}")
        return DEFAULT_RSS_FEEDS

def save_rss_feeds(feeds):
    """保存RSS源列表到文件"""
    try:
        with open(RSS_FILE, 'w', encoding='utf-8') as f:
            json.dump(feeds, f, ensure_ascii=False, indent=2)
    except Exception as e:
        logger.error(f"保存RSS源失败: {str(e)}")
        raise

def admin_only(func):
    """检查用户是否是管理员的装饰器"""
    @wraps(func)
    def wrapper(update, context, *args, **kwargs):
        user_id = update.effective_user.id
        if user_id not in load_admins():
            update.message.reply_text("⚠️ 你没有权限执行此命令")
            return
        return func(update, context, *args, **kwargs)
    return wrapper

def validate_rss_url(url):
    """验证RSS源URL是否有效"""
    try:
        feed = feedparser.parse(url)
        return hasattr(feed, 'status') and feed.status == 200
    except Exception as e:
        logger.error(f"验证RSS URL失败 {url}: {str(e)}")
        return False

def format_post(source, entry, is_official=False):
    """格式化帖子信息"""
    try:
        title = entry.title.strip()
        link = entry.link.strip()
        
        # 使用HTML格式创建可点击的标题链接
        title_link = f'<a href="{link}">{title}</a>'
        
        if is_official:
            return (
                f"〽️ <b>ClawCloud官方发布</b>\n\n"
                f"📌 标题： {title_link}\n"
                f"📲 来源：<i>{source}</i>"
            )
        else:
            return (
                f"✨️ <b>ClawCloud相关讨论</b>\n\n"
                f"📌 标题： {title_link}\n"
                f"📲 来源：<i>{source}</i>"
            )
    except Exception as e:
        logger.error(f"格式化帖子失败: {str(e)}")
        return None

def parse_rss_feed():
    """解析RSS订阅"""
    official_posts = []
    user_posts = []
    keywords = load_keywords()
    feeds = load_rss_feeds()

    for source, url in feeds.items():
        try:
            feed = feedparser.parse(url)
            
            if not hasattr(feed, 'status') or feed.status != 200:
                logger.warning(f"{source} RSS返回状态码: {getattr(feed, 'status', 'unknown')}")
                continue
                
            for entry in feed.entries:
                # 检查标题是否包含关键词
                title = entry.title.strip()
                if not any(keyword.lower() in title.lower() for keyword in keywords):
                    continue

                # 生成缓存key
                cache_key = f"{title}:{entry.link}"
                if message_cache.contains(cache_key):
                    continue

                # 添加到缓存
                message_cache.add(cache_key)

                # 格式化帖子
                formatted_post = format_post(source, entry, OFFICIAL_ID in title)
                if not formatted_post:
                    continue

                if OFFICIAL_ID in title:
                    official_posts.append(formatted_post)
                else:
                    user_posts.append(formatted_post)

        except Exception as e:
            logger.error(f"解析RSS源 {source} 失败: {str(e)}")
            continue

    return official_posts, user_posts

def check_feed(bot):
    """检查RSS源并发送消息"""
    try:
        official_posts, user_posts = parse_rss_feed()
        
        # 发送官方消息
        for post in official_posts:
            try:
                bot.send_message(chat_id=CHAT_ID, text=post, parse_mode='HTML', 
                               disable_web_page_preview=True)
                time.sleep(1)  # 避免发送过快
            except Exception as e:
                logger.error(f"发送官方消息失败: {str(e)}")

        # 发送用户讨论消息
        for post in user_posts:
            try:
                bot.send_message(chat_id=CHAT_ID, text=post, parse_mode='HTML', 
                               disable_web_page_preview=True)
                time.sleep(1)  # 避免发送过快
            except Exception as e:
                logger.error(f"发送用户消息失败: {str(e)}")

    except Exception as e:
        logger.error(f"检查RSS源失败: {str(e)}")

def run_schedule():
    """运行定时任务"""
    while True:
        try:
            schedule.run_pending()
            time.sleep(1)
        except Exception as e:
            logger.error(f"运行定时任务时发生错误: {str(e)}")
            time.sleep(60)  # 发生错误时等待1分钟再继续

@admin_only
@rate_limit
def backup_data(update, context):
    """备份所有配置数据"""
    try:
        backup_time = datetime.now().strftime('%Y%m%d_%H%M%S')
        backup_file = os.path.join(BACKUP_DIR, f'backup_{backup_time}.json')
        
        # 收集所有数据
        backup_data = {
            'keywords': load_keywords(),
            'rss_feeds': load_rss_feeds(),
            'admins': load_admins(),
            'backup_time': backup_time
        }
        
        # 保存备份
        with open(backup_file, 'w', encoding='utf-8') as f:
            json.dump(backup_data, f, ensure_ascii=False, indent=2)
            
        update.message.reply_text(f'✅ 备份完成：{backup_file}')
        
    except Exception as e:
        logger.error(f"备份数据时发生错误: {str(e)}")
        update.message.reply_text('❌ 备份数据时发生错误，请查看日志获取详细信息')

@admin_only
@rate_limit
def restore_data(update, context):
    """从备份文件恢复数据"""
    try:
        if not context.args:
            # 列出所有可用的备份文件
            backup_files = sorted([f for f in os.listdir(BACKUP_DIR) if f.startswith('backup_')])
            if not backup_files:
                update.message.reply_text('❌ 没有找到任何备份文件')
                return
            file_list = '\n'.join(backup_files)
            update.message.reply_text(f'可用的备份文件：\n\n{file_list}\n\n使用 /restore <文件名> 来恢复特定备份')
            return

        backup_file = os.path.join(BACKUP_DIR, context.args[0])
        if not os.path.exists(backup_file):
            update.message.reply_text('❌ 指定的备份文件不存在')
            return
            
        # 读取备份文件
        with open(backup_file, 'r', encoding='utf-8') as f:
            backup_data = json.load(f)
            
        # 恢复数据
        save_keywords(backup_data['keywords'])
        save_rss_feeds(backup_data['rss_feeds'])
        save_admins(backup_data['admins'])
        
        update.message.reply_text(f'✅ 已从备份文件恢复数据：{context.args[0]}')
        
    except Exception as e:
        logger.error(f"恢复数据时发生错误: {str(e)}")
        update.message.reply_text('❌ 恢复数据时发生错误，请查看日志获取详细信息')

@admin_only
@rate_limit
def add_admin(update, context):
    """添加新管理员"""
    try:
        if not context.args:
            update.message.reply_text('请提供要添加的管理员ID，例如：/add_admin 123456789')
            return

        new_admin_id = int(context.args[0])
        admins = load_admins()
        
        if new_admin_id in admins:
            update.message.reply_text(f'❌ 用户 {new_admin_id} 已经是管理员')
            return
            
        admins.append(new_admin_id)
        save_admins(admins)
        update.message.reply_text(f'✅ 已添加新管理员：{new_admin_id}')
        
    except ValueError:
        update.message.reply_text('❌ 无效的用户ID，请提供数字ID')
    except Exception as e:
        logger.error(f"添加管理员时发生错误: {str(e)}")
        update.message.reply_text('❌ 添加管理员时发生错误，请查看日志获取详细信息')

@admin_only
@rate_limit
def remove_admin(update, context):
    """移除管理员"""
    try:
        if not context.args:
            update.message.reply_text('请提供要移除的管理员ID，例如：/remove_admin 123456789')
            return

        admin_id = int(context.args[0])
        admins = load_admins()
        
        # 防止移除最后一个管理员
        if len(admins) <= 1:
            update.message.reply_text('❌ 不能移除最后一个管理员')
            return
            
        if admin_id not in admins:
            update.message.reply_text(f'❌ 用户 {admin_id} 不是管理员')
            return
            
        admins.remove(admin_id)
        save_admins(admins)
        update.message.reply_text(f'✅ 已移除管理员：{admin_id}')
        
    except ValueError:
        update.message.reply_text('❌ 无效的用户ID，请提供数字ID')
    except Exception as e:
        logger.error(f"移除管理员时发生错误: {str(e)}")
        update.message.reply_text('❌ 移除管理员时发生错误，请查看日志获取详细信息')

@admin_only
@rate_limit
def list_admins(update, context):
    """列出所有管理员"""
    try:
        admins = load_admins()
        if admins:
            admin_list = '\n'.join([f'• {admin_id}' for admin_id in admins])
            message = f'👥 当前管理员列表：\n\n{admin_list}'
        else:
            message = '❌ 当前没有设置任何管理员'
        update.message.reply_text(message)
    except Exception as e:
        logger.error(f"列出管理员时发生错误: {str(e)}")
        update.message.reply_text('❌ 获取管理员列表时发生错误，请查看日志获取详细信息')

@admin_only
@rate_limit
def add_keyword(update, context):
    """添加关键词命令处理"""
    try:
        if not context.args:
            update.message.reply_text('请提供要添加的关键词，例如：/add_keyword 新关键词')
            return

        keyword = ' '.join(context.args)
        keywords = load_keywords()
        
        if keyword.lower() in [k.lower() for k in keywords]:
            update.message.reply_text(f'❌ 关键词 "{keyword}" 已存在')
            return
            
        keywords.append(keyword)
        save_keywords(keywords)
        update.message.reply_text(f'✅ 已添加关键词：{keyword}')
        
    except Exception as e:
        logger.error(f"添加关键词时发生错误: {str(e)}")
        update.message.reply_text('❌ 添加关键词时发生错误，请查看日志获取详细信息')

@admin_only
@rate_limit
def remove_keyword(update, context):
    """删除关键词命令处理"""
    try:
        if not context.args:
            update.message.reply_text('请提供要删除的关键词，例如：/remove_keyword 关键词')
            return

        keyword = ' '.join(context.args)
        keywords = load_keywords()
        
        keyword_lower = keyword.lower()
        original_keyword = next((k for k in keywords if k.lower() == keyword_lower), None)
        
        if original_keyword:
            keywords.remove(original_keyword)
            save_keywords(keywords)
            update.message.reply_text(f'✅ 已删除关键词：{original_keyword}')
        else:
            update.message.reply_text(f'❌ 未找到关键词：{keyword}')
            
    except Exception as e:
        logger.error(f"删除关键词时发生错误: {str(e)}")
        update.message.reply_text('❌ 删除关键词时发生错误，请查看日志获取详细信息')

@admin_only
@rate_limit
def list_keywords(update, context):
    """列出所有关键词命令处理"""
    try:
        keywords = load_keywords()
        if keywords:
            keyword_list = '\n'.join([f'• {keyword}' for keyword in keywords])
            message = f'📝 当前监控的关键词列表：\n\n{keyword_list}'
        else:
            message = '❌ 当前没有设置任何关键词'
        update.message.reply_text(message)
    except Exception as e:
        logger.error(f"列出关键词时发生错误: {str(e)}")
        update.message.reply_text('❌ 获取关键词列表时发生错误，请查看日志获取详细信息')

@admin_only
@rate_limit
def add_rss_feed(update, context):
    """添加RSS源命令处理"""
    try:
        if len(context.args) < 2:
            update.message.reply_text('请提供RSS源名称和URL，例如：/add_rss NodeSeek https://rss.nodeseek.com')
            return

        name = context.args[0]
        url = context.args[1]
        feeds = load_rss_feeds()
        
        if name.lower() in [k.lower() for k in feeds.keys()]:
            update.message.reply_text(f'❌ RSS源 "{name}" 已存在')
            return
        
        update.message.reply_text(f'🔍 正在验证RSS源 "{name}"...')
        if not validate_rss_url(url):
            update.message.reply_text(f'❌ RSS源 "{url}" 无效或无法访问')
            return
            
        feeds[name] = url
        save_rss_feeds(feeds)
        update.message.reply_text(f'✅ 已添加RSS源：{name} ({url})')
        
    except Exception as e:
        logger.error(f"添加RSS源时发生错误: {str(e)}")
        update.message.reply_text('❌ 添加RSS源时发生错误，请查看日志获取详细信息')

@admin_only
@rate_limit
def remove_rss_feed(update, context):
    """删除RSS源命令处理"""
    try:
        if not context.args:
            update.message.reply_text('请提供要删除的RSS源名称，例如：/remove_rss NodeSeek')
            return

        name = context.args[0]
        feeds = load_rss_feeds()
        
        name_lower = name.lower()
        original_name = next((k for k in feeds.keys() if k.lower() == name_lower), None)
        
        if original_name:
            del feeds[original_name]
            save_rss_feeds(feeds)
            update.message.reply_text(f'✅ 已删除RSS源：{original_name}')
        else:
            update.message.reply_text(f'❌ 未找到RSS源：{name}')
            
    except Exception as e:
        logger.error(f"删除RSS源时发生错误: {str(e)}")
        update.message.reply_text('❌ 删除RSS源时发生错误，请查看日志获取详细信息')

@admin_only
@rate_limit
def list_rss_feeds(update, context):
    """列出所有RSS源命令处理"""
    try:
        feeds = load_rss_feeds()
        if feeds:
            feed_list = '\n'.join([f'• {name}: {url}' for name, url in feeds.items()])
            message = f'📝 当前监控的RSS源列表：\n\n{feed_list}'
        else:
            message = '❌ 当前没有设置任何RSS源'
        update.message.reply_text(message)
    except Exception as e:
        logger.error(f"列出RSS源时发生错误: {str(e)}")
        update.message.reply_text('❌ 获取RSS源列表时发生错误，请查看日志获取详细信息')

@admin_only
@rate_limit
def status(update, context):
    """处理 /status 命令"""
    try:
        keywords = load_keywords()
        feeds = load_rss_feeds()
        admins = load_admins()
        
        status_msg = (
            "🤖 机器人状态\n\n"
            f"👥 管理员数量: {len(admins)}\n"
            f"📝 监控关键词数量: {len(keywords)}\n"
            f"📡 RSS源数量: {len(feeds)}\n"
            f"⏱ 检查间隔: {CHECK_INTERVAL}秒\n"
            f"💾 缓存时间: {CACHE_DURATION//3600}小时"
        )
        update.message.reply_text(status_msg)
    except Exception as e:
        logger.error(f"处理status命令失败: {str(e)}")

def start(update, context):
    """处理 /start 命令"""
    try:
        user_id = update.effective_user.id
        is_admin = user_id in load_admins()
        
        welcome_msg = (
            "👋 你好！我是RSS监控机器人\n\n"
            "🔍 我可以帮你监控RSS源中的关键词\n\n"
        )
        
        if is_admin:
            welcome_msg += (
                "管理员命令：\n"
                "/add_keyword <关键词> - 添加监控关键词\n"
                "/remove_keyword <关键词> - 删除监控关键词\n"
                "/list_keywords - 查看所有监控关键词\n"
                "/add_rss <名称> <URL> - 添加RSS源\n"
                "/remove_rss <名称> - 删除RSS源\n"
                "/list_rss - 查看所有RSS源\n"
                "/add_admin <用户ID> - 添加管理员\n"
                "/remove_admin <用户ID> - 移除管理员\n"
                "/list_admins - 查看所有管理员\n"
                "/backup - 备份配置数据\n"
                "/restore - 恢复配置数据\n"
                "/status - 查看机器人状态"
            )
        else:
            welcome_msg += "你没有管理员权限，只能查看机器人的推送消息。"
            
        update.message.reply_text(welcome_msg)
    except Exception as e:
        logger.error(f"处理start命令失败: {str(e)}")

def error_handler(update, context):
    """处理错误的回调函数"""
    try:
        logger.error(f"Update {update} caused error {context.error}")
    except Exception as e:
        logger.error(f"Error handler failed: {str(e)}")

def main():
    """主函数"""
    try:
        logger.info("Starting bot...")
        updater = Updater(TELEGRAM_TOKEN, use_context=True)
        dp = updater.dispatcher
        
        # 添加命令处理器
        dp.add_handler(CommandHandler("start", start))
        dp.add_handler(CommandHandler("status", status))
        dp.add_handler(CommandHandler("add_keyword", add_keyword))
        dp.add_handler(CommandHandler("remove_keyword", remove_keyword))
        dp.add_handler(CommandHandler("list_keywords", list_keywords))
        dp.add_handler(CommandHandler("add_rss", add_rss_feed))
        dp.add_handler(CommandHandler("remove_rss", remove_rss_feed))
        dp.add_handler(CommandHandler("list_rss", list_rss_feeds))
        dp.add_handler(CommandHandler("add_admin", add_admin))
        dp.add_handler(CommandHandler("remove_admin", remove_admin))
        dp.add_handler(CommandHandler("list_admins", list_admins))
        dp.add_handler(CommandHandler("backup", backup_data))
        dp.add_handler(CommandHandler("restore", restore_data))
        
        # 添加错误处理器
        dp.add_error_handler(error_handler)
        
        # 启动机器人
        updater.start_polling()
        logger.info("Bot started successfully")
        
        # 启动定时任务
        schedule.every(CHECK_INTERVAL).seconds.do(check_feed, updater.bot)
        
        # 启动定时任务线程
        schedule_thread = threading.Thread(target=run_schedule)
        schedule_thread.daemon = True
        schedule_thread.start()
        
        # 定期清理过期缓存
        def clean_cache():
            message_cache.clear_expired()
        schedule.every(12).hours.do(clean_cache)
        
        # 等待机器人运行
        updater.idle()
        
    except Exception as e:
        logger.error(f"Bot startup failed: {str(e)}")
        sys.exit(1)

if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        logger.info("Bot stopped by user")
        sys.exit(0)
    except Exception as e:
        logger.error(f"Bot crashed: {str(e)}")
        sys.exit(1)
EOF

# 设置权限
chmod +x "$APP_DIR/bot.py"
chown -R "$APP_USER:$APP_USER" "$APP_DIR"
chown -R "$APP_USER:$APP_USER" "$LOG_DIR"

# 创建supervisor配置文件
cat > "/etc/supervisor/conf.d/$SERVICE_NAME.conf" << EOF
[program:$SERVICE_NAME]
command=$VENV_DIR/bin/python $APP_DIR/bot.py
directory=$APP_DIR
user=$APP_USER
autostart=true
autorestart=true
stderr_logfile=/var/log/$SERVICE_NAME/err.log
stdout_logfile=/var/log/$SERVICE_NAME/out.log
EOF

# 重新加载supervisor配置
supervisorctl reread
supervisorctl update

# 启动服务
supervisorctl start "$SERVICE_NAME"

# 检查服务状态
sleep 5
if ! supervisorctl status "$SERVICE_NAME" | grep -q "RUNNING"; then
    error_exit "服务未能正常启动"
fi

echo "部署完成！"
echo "使用以下命令管理服务："
echo "- 查看状态：supervisorctl status $SERVICE_NAME"
echo "- 重启服务：supervisorctl restart $SERVICE_NAME"
echo "- 停止服务：supervisorctl stop $SERVICE_NAME"
echo "- 查看日志：tail -f /var/log/$SERVICE_NAME/err.log"
