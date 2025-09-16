#!/usr/bin/env bash
# =========================================================
# backup.sh — Sao lưu DELTA/FULL + Log + Retention + Email
# Yêu cầu: GNU tar, find; và mailutils/sendmail nếu muốn email
# Cách dùng: ./backup.sh <thu_muc_nguon> <thu_muc_dich>
# =========================================================
set -Eeuo pipefail
IFS=$'\n\t'

# --------------------------
# CẤU HÌNH
# --------------------------
# Email nhận thông báo (để trống = không gửi email)
EMAIL_TO="phuonganhdt73@gmail.com"

# Nếu KHÔNG có thay đổi 24h thì fallback sang FULL? (true/false)
FULL_IF_NO_CHANGE=true

# Nếu DELTA sau khi lọc exclude trống, có fallback sang FULL không?
DELTA_FALLBACK_TO_FULL_WHEN_EMPTY=true

# Giữ lại N bản mới nhất (0 = không xóa bản cũ)
RETENTION_KEEP=5

# Loại trừ (áp dụng cho FULL, và dùng để lọc DELTA)
# Mẫu dạng glob, tính theo đường dẫn TƯƠNG ĐỐI với SRC (vd: ".git", "node_modules/*", "*.log")
EXCLUDES=( ".git" "node_modules" "*.log" )

# --------------------------
# HÀM HỖ TRỢ
# --------------------------
abs_path() {
  # Trả về đường dẫn tuyệt đối, tương đương realpath -m
  if command -v realpath >/dev/null 2>&1; then
    realpath -m -- "$1"
  else
    # fallback
    readlink -f -- "$1" 2>/dev/null || echo "$1"
  fi
}

calc_sha256() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    echo "n/a"
  fi
}

send_email() {
  local subject="$1"; shift
  local body="$*"
  [[ -z "$EMAIL_TO" ]] && return 0
  if command -v mail >/dev/null 2>&1; then
    printf "%s\n" "$body" | mail -s "$subject" "$EMAIL_TO" || true
  elif command -v sendmail >/dev/null 2>&1; then
    {
      printf "To: %s\n" "$EMAIL_TO"
      printf "Subject: %s\n" "$subject"
      printf "Content-Type: text/plain; charset=UTF-8\n\n"
      printf "%s\n" "$body"
    } | sendmail -t || true
  fi
}

log_line() { echo "$*" | tee -a "$RUN_LOG" >/dev/null; }

on_error() {
  local line="$1"; local cmd="$2"
  local msg="Sao lưu THẤT BẠI tại dòng $line: $cmd"
  log_line "ERROR: $msg"
  # gửi email lỗi (nếu bật)
  send_email "Backup THẤT BẠI: ${SRC_NAME}" \
"Backup thất bại.

• Thời gian : $(date)
• Nguồn     : $SRC
• Đích      : $DST
• Dòng lỗi  : $line
• Lệnh      : $cmd

Xem thêm log phiên: $RUN_LOG
"
  exit 1
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# --------------------------
# THAM SỐ
# --------------------------
if [[ $# -ne 2 ]]; then
  echo "Cách dùng: $(basename "$0") <thu_muc_nguon> <thu_muc_dich>" >&2
  exit 1
fi

SRC="$(abs_path "$1")"
DST="$(abs_path "$2")"
[[ -d "$SRC" ]] || { echo "Lỗi: Không thấy thư mục nguồn: $SRC" >&2; exit 1; }
mkdir -p "$DST"

# --------------------------
# THIẾT LẬP
# --------------------------
TS_UTC="$(date -u +%Y%m%d-%H%M%S)"
TS_LOCAL="$(date +%Y%m%d-%H%M%S)"
SRC_NAME="$(basename "$SRC")"
BACKUP_NAME="backup-${SRC_NAME}-${TS_LOCAL}.tar.gz"
TMP_ARCHIVE="${DST}/.${BACKUP_NAME}.tmp"
FINAL_ARCHIVE="${DST}/${BACKUP_NAME}"
LOG_FILE="${DST}/backup.log"
RUN_LOG="${DST}/backup.run.${TS_LOCAL}.log"   # log theo phiên chạy
TS_24H_AGO_ISO="$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
START_SEC="$(date +%s)"

: > "$RUN_LOG"  # tạo/clear log phiên
log_line "=== BẮT ĐẦU BACKUP @ $(date) ==="
log_line "Nguồn : $SRC"
log_line "Đích  : $DST"

# --------------------------
# TÌM FILE THAY ĐỔI (ĐỆ QUY)
# --------------------------
log_line "Đang quét thay đổi trong 24h (kể cả file ẩn)..."
mapfile -d '' CHANGED_ABS < <(find "$SRC" -type f -newermt "$TS_24H_AGO_ISO" -print0 || true)
CHANGED_REL=()
if ((${#CHANGED_ABS[@]} > 0)); then
  for f in "${CHANGED_ABS[@]}"; do
    CHANGED_REL+=( "${f#$SRC/}" )
  done
fi

# Lọc theo EXCLUDES cho DELTA
match_excludes() {
  local p="$1"
  for pat in "${EXCLUDES[@]}"; do
    # khớp glob (shopt globstar mặc định ok)
    [[ "$p" == $pat || "$p" == ./$pat ]] && return 0
    # khớp theo prefix thư mục
    [[ "$pat" != *'*'* ]] && [[ "$p" == "$pat/"* ]] && return 0
  done
  return 1
}

FILTERED_REL=()
if ((${#CHANGED_REL[@]} > 0)); then
  for r in "${CHANGED_REL[@]}"; do
    if match_excludes "$r"; then
      log_line "Bỏ qua (exclude): $r"
      continue
    fi
    FILTERED_REL+=( "$r" )
  done
fi

# --------------------------
# TẠO BACKUP
# --------------------------
MODE=""
if ((${#FILTERED_REL[@]} == 0)); then
  if [[ "$FULL_IF_NO_CHANGE" == "true" ]]; then
    MODE="FULL"
    log_line "Không có thay đổi (sau lọc) → Sao lưu TOÀN BỘ."
  else
    log_line "Không có thay đổi (sau lọc) → Dừng, không tạo backup."
    exit 0
  fi
else
  MODE="DELTA-24H"
  log_line "Phát hiện thay đổi → Sao lưu DELTA (${#FILTERED_REL[@]} tệp)."
fi

# Đối số exclude cho FULL
EXCLUDE_ARGS=()
if ((${#EXCLUDES[@]} > 0)); then
  for pat in "${EXCLUDES[@]}"; do
    EXCLUDE_ARGS+=( --exclude="$pat" )
  done
fi

if [[ "$MODE" == "FULL" ]]; then
  tar "${EXCLUDE_ARGS[@]}" -C "$SRC" -czf "$TMP_ARCHIVE" .
else
  # Nếu DELTA rỗng vì exclude và muốn fallback FULL
  if ((${#FILTERED_REL[@]} == 0)) && [[ "$DELTA_FALLBACK_TO_FULL_WHEN_EMPTY" == "true" ]]; then
    MODE="FULL"
    log_line "DELTA rỗng sau exclude → Fallback sang FULL."
    tar "${EXCLUDE_ARGS[@]}" -C "$SRC" -czf "$TMP_ARCHIVE" .
  else
    # Truyền danh sách file an toàn qua stdin (null-terminated)
    printf '%s\0' "${FILTERED_REL[@]}" \
      | tar --null -C "$SRC" -T - -czf "$TMP_ARCHIVE"
  fi
fi

# Di chuyển file tạm thành file chính thức (gần-atomic)
mv -f "$TMP_ARCHIVE" "$FINAL_ARCHIVE"

SIZE_BYTES=$(stat -c%s "$FINAL_ARCHIVE" 2>/dev/null || wc -c <"$FINAL_ARCHIVE")
SHA256_VAL="$(calc_sha256 "$FINAL_ARCHIVE")"
DURATION=$(( $(date +%s) - START_SEC ))

log_line "Đã tạo: $FINAL_ARCHIVE"
log_line "Kích thước: $SIZE_BYTES bytes, SHA256: $SHA256_VAL, Thời gian: ${DURATION}s"

# --------------------------
# GHI LOG TỔNG
# --------------------------
{
  echo "------------------------------------"
  echo "Thời gian           : $(date)"
  echo "Nguồn               : $SRC"
  echo "Đích                : $DST"
  echo "File backup         : $BACKUP_NAME"
  echo "Chế độ              : $MODE"
  echo "Số tệp (DELTA)      : ${#FILTERED_REL[@]}"
  echo "Kích thước (bytes)  : $SIZE_BYTES"
  echo "SHA256              : $SHA256_VAL"
  echo "Thời lượng (giây)   : $DURATION"
} >> "$LOG_FILE"

# --------------------------
# EMAIL THÀNH CÔNG
# --------------------------
send_email "Backup THÀNH CÔNG: ${BACKUP_NAME}" \
"Backup hoàn tất.

• Thời gian          : $(date)
• Chế độ             : $MODE
• File/Directory     : $SRC
• Nơi lưu trữ        : $DST
• Tệp                : $BACKUP_NAME
• Số tệp             : ${#FILTERED_REL[@]}
• Size (bytes)       : $SIZE_BYTES
• SHA256             : $SHA256_VAL

Log tổng             : $LOG_FILE
Log phiên            : $RUN_LOG
"

# --------------------------
# RETENTION: GIỮ N BẢN MỚI NHẤT
# --------------------------
if (( RETENTION_KEEP > 0 )); then
  mapfile -d '' OLD_FILES < <(
    find "$DST" -maxdepth 1 -type f -name "backup-${SRC_NAME}-*.tar.gz" -printf '%T@ %p\0' \
    | sort -znr \
    | awk -v RS='\0' -v keep="$RETENTION_KEEP" 'NR>keep {sub(/^[^ ]+ /,""); print}' ORS='\0'
  )
  if ((${#OLD_FILES[@]} > 0)); then
    log_line "Dọn dẹp bản cũ (giữ lại ${RETENTION_KEEP} bản mới nhất)..."
    xargs -0r rm -- <<<"$(printf '%s\0' "${OLD_FILES[@]}")"
  fi
fi

log_line "=== HOÀN TẤT @ $(date) ==="
exit 0

# --------------------------
# (TÙY CHỌN) MÃ HÓA GPG SAU KHI NÉN (bật bằng tay)
# --------------------------
# Ví dụ mã hóa đối xứng:
# gpg --yes --batch --symmetric --cipher-algo AES256 --output "${FINAL_ARCHIVE}.gpg" "$FINAL_ARCHIVE"
# shred -u "$FINAL_ARCHIVE"
