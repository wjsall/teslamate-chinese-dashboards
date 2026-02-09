#!/bin/bash
BASE="https://raw.githubusercontent.com/wjsall/teslamate-chinese-dashboards/d8ab9a5"

files=(
  "i18n_fix_chart_labels.py"
  "i18n_fix_remaining.py"
  "i18n_fix_sql.py"
  "i18n_fix_sql_batch.py"
  "i18n_full_audit.py"
  "i18n_quality_check.py"
  "i18n_rollback_sql.py"
  "i18n_round2.py"
  "i18n_round3.py"
  "i18n_round4.py"
  "i18n_round5.py"
  "i18n_safe_translate.py"
  "i18n_strict_audit.py"
  "i18n_translate_desc.py"
  "i18n_translate_labels.py"
  "optimize_maps.py"
  "upload.sh"
)

for file in "${files[@]}"; do
  curl -sL "$BASE/$file" -o "$file" && echo "Downloaded: $file" || echo "Failed: $file"
  sleep 1
done

# Download images
mkdir -p images
curl -sL "$BASE/images/alipay-donate.jpg" -o "images/alipay-donate.jpg" && echo "Downloaded: alipay-donate.jpg" || echo "Failed: alipay-donate.jpg"
curl -sL "$BASE/images/wechat-donate.jpg" -o "images/wechat-donate.jpg" && echo "Downloaded: wechat-donate.jpg" || echo "Failed: wechat-donate.jpg"
