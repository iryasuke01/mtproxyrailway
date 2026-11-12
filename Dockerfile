# syntax=docker/dockerfile:1
# ---------------------------------------------------------------
# Telegram MTProto Proxy (mtg v2) - طراحی‌شده برای Railway
# ---------------------------------------------------------------
ARG GO_VERSION=1.23
ARG ALPINE_VERSION=3.20

# --- مرحله ۱: ساخت باینری mtg از سورس رسمی با نسخه ثابت ---
FROM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS build
ARG MTG_VERSION=2.1.7
ENV CGO_ENABLED=0
RUN go install -trimpath -ldflags="-s -w" "github.com/9seconds/mtg/v2@v${MTG_VERSION}" \
 && install -D /go/bin/mtg /out/mtg

# --- مرحله ۲: ایمیج نهایی کوچک ---
FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache tini su-exec netcat-openbsd ca-certificates tzdata \
 && adduser -D -H -s /sbin/nologin mtg \
 && mkdir -p /data \
 && chown mtg:mtg /data

COPY --from=build /out/mtg /usr/local/bin/mtg
COPY entrypoint.sh /entrypoint.sh
# آپلود از مرورگر گوشی، دسترسی اجرایی فایل را حفظ نمی‌کند؛ پس اینجا تنظیم می‌شود
RUN chmod 0755 /entrypoint.sh /usr/local/bin/mtg

# پورت داخلی پیش‌فرض (می‌توانید با متغیر MTG_PORT عوض کنید)
ENV MTG_PORT=8443
EXPOSE 8443

# توجه: Railway این HEALTHCHECK را نادیده می‌گیرد (فقط HTTP را پشتیبانی می‌کند)
# ولی برای اجرا روی سایر هاست‌های Docker مفید است.
HEALTHCHECK --interval=60s --timeout=5s --start-period=20s --retries=3 \
  CMD nc -z 127.0.0.1 "${MTG_PORT:-8443}" || exit 1

# entrypoint ابتدا root است فقط برای تنظیم مجوز Volume، سپس به کاربر mtg می‌رود
ENTRYPOINT ["/sbin/tini", "--", "/bin/sh", "/entrypoint.sh"]
