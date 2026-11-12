#!/bin/sh
# ---------------------------------------------------------------
# entrypoint.sh - مدیریت اجرای mtg (Telegram MTProto Proxy) روی Railway
#  - تنظیم مجوز Volume و رفتن به کاربر غیر root
#  - ساخت/خواندن Secret
#  - ساخت فایل پیکربندی
#  - اجرای mtg با راه‌اندازی مجدد خودکار
#  - پایش سلامت و نوشتن پیام‌های قابل فهم در Logs
# ---------------------------------------------------------------
set -u

APP_USER="mtg"
MTG_BIN="/usr/local/bin/mtg"

# ---------- توابع لاگ ----------
ts()   { date -u '+%Y-%m-%d %H:%M:%S'; }
info() { printf '%s [INFO]  %s\n' "$(ts)" "$1"; }
warn() { printf '%s [WARN]  %s\n' "$(ts)" "$1"; }
err()  { printf '%s [ERROR] %s\n' "$(ts)" "$1" >&2; }

is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# ---------- تنظیمات (همه از متغیر محیطی) ----------
MTG_PORT="${MTG_PORT:-${RAILWAY_TCP_APPLICATION_PORT:-8443}}"
MTG_BIND_HOST="${MTG_BIND_HOST:-0.0.0.0}"
MTG_FAKE_TLS_DOMAIN="${MTG_FAKE_TLS_DOMAIN:-www.google.com}"
MTG_CONCURRENCY="${MTG_CONCURRENCY:-1024}"
MTG_PREFER_IP="${MTG_PREFER_IP:-prefer-ipv4}"
LOG_SECRET="${LOG_SECRET:-true}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-30}"
HEARTBEAT_MIN="${HEARTBEAT_MIN:-15}"
MEM_WARN_PCT="${MEM_WARN_PCT:-85}"
MEM_WARN_MB="${MEM_WARN_MB:-400}"
CPU_WARN_PCT="${CPU_WARN_PCT:-90}"
DISK_WARN_PCT="${DISK_WARN_PCT:-85}"
DISK_CRIT_PCT="${DISK_CRIT_PCT:-95}"
HAS_VOLUME=0
[ -n "${RAILWAY_VOLUME_MOUNT_PATH:-}" ] && HAS_VOLUME=1
DATA_DIR="${RAILWAY_VOLUME_MOUNT_PATH:-${DATA_DIR:-/data}}"
RUN_DIR="/tmp/mtg-run"

# ---------- مرحله root: فقط مجوز Volume، بعد افت دسترسی ----------
if [ "$(id -u)" = "0" ] && [ "${_MTG_DROPPED:-0}" != "1" ]; then
  mkdir -p "$DATA_DIR" 2>/dev/null
  if command -v su-exec >/dev/null 2>&1 && id "$APP_USER" >/dev/null 2>&1; then
    chown -R "$APP_USER:$APP_USER" "$DATA_DIR" 2>/dev/null \
      || warn "تنظیم مجوز پوشه $DATA_DIR ممکن نشد؛ اگر Volume دارید، ذخیره‌سازی پایدار ممکن است کار نکند."
    export _MTG_DROPPED=1
    exec su-exec "$APP_USER" /bin/sh "$0" "$@"
  else
    warn "امکان اجرا با کاربر غیر root نبود؛ برنامه با دسترسی فعلی اجرا می‌شود."
  fi
fi

info "راه‌اندازی Telegram MTProto Proxy (mtg) — کاربر: $(id -un 2>/dev/null || id -u)"

# ---------- اعتبارسنجی تنظیمات ----------
if ! is_uint "$MTG_PORT" || [ "$MTG_PORT" -lt 1 ] || [ "$MTG_PORT" -gt 65535 ]; then
  err "مقدار MTG_PORT معتبر نیست ('$MTG_PORT'). یک عدد بین 1 تا 65535 بگذارید (پیشنهاد: 8443)."
  exit 64
fi
if ! is_uint "$MTG_CONCURRENCY" || [ "$MTG_CONCURRENCY" -lt 1 ]; then
  err "مقدار MTG_CONCURRENCY معتبر نیست ('$MTG_CONCURRENCY'). یک عدد مثبت بگذارید (مثلاً 1024)."
  exit 64
fi
case "$MTG_PREFER_IP" in
  prefer-ipv4|prefer-ipv6|only-ipv4|only-ipv6) ;;
  *) err "مقدار MTG_PREFER_IP معتبر نیست ('$MTG_PREFER_IP'). یکی از prefer-ipv4 / prefer-ipv6 / only-ipv4 / only-ipv6."; exit 64 ;;
esac
for v in HEALTH_INTERVAL HEARTBEAT_MIN MEM_WARN_PCT MEM_WARN_MB CPU_WARN_PCT DISK_WARN_PCT DISK_CRIT_PCT; do
  eval "val=\${$v}"
  if ! is_uint "$val" || [ "$val" -lt 1 ]; then
    err "مقدار $v معتبر نیست ('$val'). یک عدد صحیح مثبت بگذارید یا متغیر را حذف کنید."
    exit 64
  fi
done

if [ -n "${RAILWAY_TCP_APPLICATION_PORT:-}" ] && [ "$RAILWAY_TCP_APPLICATION_PORT" != "$MTG_PORT" ]; then
  warn "پورت داخلی برنامه ($MTG_PORT) با «Application Port» تعریف‌شده در TCP Proxy ($RAILWAY_TCP_APPLICATION_PORT) یکی نیست. ترافیک به برنامه نمی‌رسد! در Railway > Settings > Networking > TCP Proxy پورت را روی $MTG_PORT بگذارید یا MTG_PORT را برابر $RAILWAY_TCP_APPLICATION_PORT کنید."
fi

# ---------- آماده‌سازی پوشه‌ها ----------
mkdir -p "$DATA_DIR" 2>/dev/null
PERSIST=1
if [ ! -d "$DATA_DIR" ] || [ ! -w "$DATA_DIR" ]; then
  warn "پوشه $DATA_DIR قابل نوشتن نیست؛ از پوشه موقت استفاده می‌شود و داده‌ها پایدار نخواهند بود."
  DATA_DIR="/tmp/mtg-data"
  mkdir -p "$DATA_DIR" 2>/dev/null
  PERSIST=0
fi
mkdir -p "$RUN_DIR" 2>/dev/null || { err "ساخت پوشه $RUN_DIR ممکن نشد."; exit 70; }

if [ "$HAS_VOLUME" = "0" ]; then
  warn "Volume متصل نیست. اگر MTG_SECRET را به‌صورت متغیر تنظیم نکنید، با هر Deploy جدید Secret عوض می‌شود و لینک قبلی از کار می‌افتد."
fi

# ---------- Secret ----------
SECRET="${MTG_SECRET:-}"
SECRET_SRC="variable"
SECRET_FILE="$DATA_DIR/secret"
if [ -z "$SECRET" ] && [ -s "$SECRET_FILE" ]; then
  SECRET="$(tr -d ' \r\n' < "$SECRET_FILE")"
  SECRET_SRC="volume"
fi
if [ -z "$SECRET" ]; then
  info "Secret پیدا نشد؛ یک Secret تصادفی (رمزنگاری‌شده) ساخته می‌شود."
  SECRET="$("$MTG_BIN" generate-secret --hex "$MTG_FAKE_TLS_DOMAIN" 2>/dev/null | tr -d ' \r\n')"
  SECRET_SRC="generated"
  if [ -z "$SECRET" ]; then
    err "ساخت Secret ناموفق بود. مقدار MTG_FAKE_TLS_DOMAIN ('$MTG_FAKE_TLS_DOMAIN') باید یک نام دامنه معتبر باشد."
    exit 65
  fi
  if [ "$PERSIST" = "1" ] && [ "$HAS_VOLUME" = "1" ]; then
    ( umask 077; printf '%s\n' "$SECRET" > "$SECRET_FILE" ) 2>/dev/null \
      && info "Secret در Volume ذخیره شد و با Restart عوض نمی‌شود." \
      || warn "ذخیره Secret در Volume ناموفق بود."
  fi
fi
if ! printf '%s' "$SECRET" | grep -Eq '^ee[0-9a-fA-F]{34,}$'; then
  err "فرمت Secret درست نیست. باید رشته hex باشد و با ee شروع شود (مثل خروجی mtg generate-secret --hex). برای ساخت Secret جدید متغیر MTG_SECRET را حذف کنید."
  exit 65
fi

# ---------- فایل پیکربندی ----------
BIND_HOST="$MTG_BIND_HOST"
case "$BIND_HOST" in *:*) BIND_HOST="[$BIND_HOST]" ;; esac
CONF="$RUN_DIR/config.toml"
( umask 077
  cat > "$CONF" <<EOF
secret = "$SECRET"
bind-to = "$BIND_HOST:$MTG_PORT"
concurrency = $MTG_CONCURRENCY
prefer-ip = "$MTG_PREFER_IP"
EOF
) || { err "نوشتن فایل پیکربندی ناموفق بود ($CONF)."; exit 70; }

# ---------- نمایش اطلاعات اتصال (فقط با مقادیر واقعی Railway) ----------
print_connection_info() {
  if [ -n "${RAILWAY_TCP_PROXY_DOMAIN:-}" ] && [ -n "${RAILWAY_TCP_PROXY_PORT:-}" ]; then
    info "----------------- اطلاعات اتصال -----------------"
    info "Server : $RAILWAY_TCP_PROXY_DOMAIN"
    info "Port   : $RAILWAY_TCP_PROXY_PORT   (پورت عمومی Railway؛ پورت داخلی برنامه: $MTG_PORT)"
    if [ "$LOG_SECRET" = "true" ]; then
      info "Secret : $SECRET   (منبع: $SECRET_SRC)"
      info "لینک   : tg://proxy?server=$RAILWAY_TCP_PROXY_DOMAIN&port=$RAILWAY_TCP_PROXY_PORT&secret=$SECRET"
      info "لینک وب: https://t.me/proxy?server=$RAILWAY_TCP_PROXY_DOMAIN&port=$RAILWAY_TCP_PROXY_PORT&secret=$SECRET"
      info "پس از ذخیره لینک، برای امنیت بیشتر متغیر LOG_SECRET=false بگذارید تا Secret در Logs چاپ نشود."
    else
      info "Secret به‌دلیل LOG_SECRET=false چاپ نمی‌شود؛ آن را از متغیر MTG_SECRET یا فایل secret در Volume بردارید."
    fi
    info "-------------------------------------------------"
  else
    warn "TCP Proxy هنوز فعال نشده (متغیرهای RAILWAY_TCP_PROXY_DOMAIN/PORT وجود ندارند)، پس لینک ساخته نمی‌شود."
    warn "در Railway: سرویس > Settings > Networking > TCP Proxy > پورت $MTG_PORT را وارد و تأیید کنید؛ سپس Redeploy."
    if [ "$SECRET_SRC" = "generated" ] && [ "$LOG_SECRET" = "true" ]; then
      info "Secret ساخته‌شده: $SECRET"
    fi
  fi
}
print_connection_info

# ---------- توابع پایش ----------
port_open() { nc -z -w 3 127.0.0.1 "$MTG_PORT" >/dev/null 2>&1; }

dc_reachable() {
  for ip in 149.154.167.51 149.154.175.50 149.154.167.91 91.108.56.100; do
    nc -z -w 3 "$ip" 443 >/dev/null 2>&1 && return 0
  done
  return 1
}

count_conns() {
  awk -v hp="$(printf '%04X' "$MTG_PORT")" '
    FNR > 1 { split($2, a, ":"); if (a[2] == hp && $4 == "01") n++ }
    END { print n + 0 }' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

mem_usage_mb() {
  _b=""
  if [ -r /sys/fs/cgroup/memory.current ]; then _b="$(cat /sys/fs/cgroup/memory.current 2>/dev/null)"
  elif [ -r /sys/fs/cgroup/memory/memory.usage_in_bytes ]; then _b="$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null)"; fi
  is_uint "$_b" && echo $((_b / 1048576))
}

mem_limit_mb() {
  _b=""
  if [ -r /sys/fs/cgroup/memory.max ]; then _b="$(cat /sys/fs/cgroup/memory.max 2>/dev/null)"
  elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then _b="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)"; fi
  if is_uint "$_b" && [ "${#_b}" -lt 16 ]; then echo $((_b / 1048576)); fi
}

proc_ticks() {
  sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{ print $12 + $13 }'
}

disk_pct() {
  df -Pk "$DATA_DIR" 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print $5 }'
}

# وضعیت‌های قبلی (برای جلوگیری از تکرار پیام و اعلام بازیابی)
PORT_FAILS=0; DC_STATE="unknown"; DISK_STATE="ok"; MEM_STATE="ok"; CPU_STREAK=0
LAST_TICKS=""; BEAT=0; MTG_PID=""

run_checks() {
  # ۱) پورت داخلی
  if port_open; then
    [ "$PORT_FAILS" -ge 1 ] && info "پورت داخلی $MTG_PORT دوباره در دسترس است."
    PORT_FAILS=0
  else
    PORT_FAILS=$((PORT_FAILS + 1))
    err "پورت داخلی $MTG_PORT پاسخ نمی‌دهد (دفعه $PORT_FAILS از 3). ممکن است mtg گیر کرده باشد."
    if [ "$PORT_FAILS" -ge 3 ]; then
      err "پورت سه بار پیاپی پاسخ نداد؛ mtg برای راه‌اندازی مجدد متوقف می‌شود."
      kill -TERM "$MTG_PID" 2>/dev/null; sleep 2; kill -KILL "$MTG_PID" 2>/dev/null
      PORT_FAILS=0
      return
    fi
  fi

  # ۲) ارتباط با سرورهای تلگرام
  if dc_reachable; then
    [ "$DC_STATE" = "down" ] && info "ارتباط با سرورهای تلگرام دوباره برقرار شد."
    DC_STATE="up"
  else
    if [ "$DC_STATE" != "down" ]; then
      err "هیچ‌کدام از سرورهای تلگرام (پورت 443) از این سرویس در دسترس نیستند. تا برقراری ارتباط، پروکسی نمی‌تواند پیام‌ها را رد کند. ممکن است مشکل موقت شبکه Railway باشد."
    fi
    DC_STATE="down"
  fi

  # ۳) فضای ذخیره‌سازی
  _d="$(disk_pct)"
  if is_uint "$_d"; then
    if [ "$_d" -ge "$DISK_CRIT_PCT" ]; then
      [ "$DISK_STATE" != "crit" ] && err "فضای ذخیره‌سازی تقریباً پر است (${_d}%). اندازه Volume را در Railway افزایش دهید."
      DISK_STATE="crit"
    elif [ "$_d" -ge "$DISK_WARN_PCT" ]; then
      [ "$DISK_STATE" = "ok" ] && warn "فضای ذخیره‌سازی رو به پر شدن است (${_d}%)."
      DISK_STATE="warn"
    else
      [ "$DISK_STATE" != "ok" ] && info "فضای ذخیره‌سازی به حالت عادی برگشت (${_d}%)."
      DISK_STATE="ok"
    fi
  fi

  # ۴) حافظه
  _m="$(mem_usage_mb)"; _l="$(mem_limit_mb)"
  if is_uint "$_m"; then
    _hi=0
    if is_uint "$_l" && [ "$_l" -gt 0 ]; then
      [ $((_m * 100 / _l)) -ge "$MEM_WARN_PCT" ] && _hi=1
    elif [ "$_m" -ge "$MEM_WARN_MB" ]; then
      _hi=1
    fi
    if [ "$_hi" = "1" ]; then
      [ "$MEM_STATE" = "ok" ] && warn "مصرف حافظه بالاست: ${_m}MB${_l:+ از ${_l}MB}. اگر ادامه یابد ممکن است سرویس توسط سیستم متوقف شود."
      MEM_STATE="high"
    else
      [ "$MEM_STATE" = "high" ] && info "مصرف حافظه به حالت عادی برگشت (${_m}MB)."
      MEM_STATE="ok"
    fi
  fi

  # ۵) CPU برنامه (درصد یک هسته؛ CLK_TCK=100)
  _t="$(proc_ticks "$MTG_PID")"
  if is_uint "$_t"; then
    if [ -n "$LAST_TICKS" ]; then
      _cpu=$(( (_t - LAST_TICKS) / HEALTH_INTERVAL ))
      if [ "$_cpu" -ge "$CPU_WARN_PCT" ]; then
        CPU_STREAK=$((CPU_STREAK + 1))
        [ "$CPU_STREAK" -eq 3 ] && warn "مصرف CPU چند بازه پیاپی بالاست (${_cpu}%). ممکن است ترافیک زیاد یا سوءاستفاده از پروکسی در جریان باشد."
      else
        CPU_STREAK=0
      fi
    fi
    LAST_TICKS="$_t"
  fi

  # ۶) گزارش دوره‌ای
  BEAT=$((BEAT + HEALTH_INTERVAL))
  if [ "$BEAT" -ge $((HEARTBEAT_MIN * 60)) ]; then
    BEAT=0
    info "گزارش: پروکسی فعال | اتصال فعال: $(count_conns) | حافظه: ${_m:-?}MB | دیسک: ${_d:-?}% | تلگرام: $DC_STATE"
  fi
}

# ---------- مدیریت سیگنال‌ها ----------
STOP=0
on_term() {
  STOP=1
  info "سیگنال توقف دریافت شد؛ در حال خاموش کردن مرتب..."
  [ -n "$MTG_PID" ] && kill -TERM "$MTG_PID" 2>/dev/null
}
trap on_term TERM INT

# ---------- حلقه اصلی: اجرا + راه‌اندازی مجدد با فاصله فزاینده ----------
FAST_FAILS=0
MAX_FAST_FAILS=5
while [ "$STOP" = "0" ]; do
  START_TS="$(date +%s)"
  "$MTG_BIN" run "$CONF" &
  MTG_PID=$!
  LAST_TICKS=""; PORT_FAILS=0; CPU_STREAK=0

  # منتظر آماده شدن پورت (تا ۱۵ ثانیه)
  READY=0
  i=0
  while [ "$i" -lt 15 ] && kill -0 "$MTG_PID" 2>/dev/null; do
    if port_open; then READY=1; break; fi
    sleep 1; i=$((i + 1))
  done
  if [ "$READY" = "1" ]; then
    info "mtg اجرا شد و روی پورت داخلی $MTG_PORT آماده دریافت اتصال است."
  elif kill -0 "$MTG_PID" 2>/dev/null; then
    warn "mtg در ۱۵ ثانیه روی پورت $MTG_PORT آماده نشد؛ پایش ادامه دارد."
  fi
  if dc_reachable; then DC_STATE="up"; else DC_STATE="down"; err "در شروع کار، سرورهای تلگرام در دسترس نیستند."; fi

  tick=0
  while kill -0 "$MTG_PID" 2>/dev/null; do
    sleep 1
    [ "$STOP" = "1" ] && break
    tick=$((tick + 1))
    if [ $((tick % HEALTH_INTERVAL)) -eq 0 ]; then run_checks; fi
  done

  wait "$MTG_PID" 2>/dev/null
  RC=$?
  [ "$STOP" = "1" ] && break

  RUNTIME=$(( $(date +%s) - START_TS ))
  case "$RC" in
    137) HINT="احتمالاً حافظه تمام شده (OOM). مصرف حافظه یا MTG_CONCURRENCY را کم کنید." ;;
    139) HINT="خطای داخلی برنامه (Segfault)." ;;
    1|2) HINT="معمولاً خطای تنظیمات است یا پورت $MTG_PORT قبلاً اشغال شده. پیام‌های بالای همین خط را بخوانید." ;;
    *)   HINT="علت دقیق‌تر را در خطوط قبلی Logs ببینید." ;;
  esac
  err "mtg متوقف شد (کد $RC) بعد از ${RUNTIME} ثانیه. $HINT"

  if [ "$RUNTIME" -lt 60 ]; then FAST_FAILS=$((FAST_FAILS + 1)); else FAST_FAILS=0; fi
  if [ "$FAST_FAILS" -ge "$MAX_FAST_FAILS" ]; then
    err "mtg ${MAX_FAST_FAILS} بار پشت سر هم بلافاصله خاموش شد. برای جلوگیری از چرخه بی‌پایان، سرویس متوقف می‌شود تا Railway بر اساس Restart Policy تصمیم بگیرد."
    exit 1
  fi
  DELAY=$((FAST_FAILS * 3 + 2))
  warn "راه‌اندازی مجدد mtg تا ${DELAY} ثانیه دیگر..."
  sleep "$DELAY"
done

info "سرویس به‌صورت مرتب خاموش شد."
exit 0
