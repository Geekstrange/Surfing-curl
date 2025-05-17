#!/bin/bash

RED_BG='\033[41;37m'    # 红底白字 Red background with white text
YELLOW_BG='\033[43;34m' # 黄底蓝字 Yellow background with blue text
GREEN_BG='\033[42;30m'  # 绿底黑字 Green background with black text
CYAN_BG='\033[46;37m'   # 青底白字 Cyan background with white text
RED_WD='\033[31m'       # 红字 Red text
YELLOW_WD='\033[33m'    # 黄字 Yellow text
GREEN_WD='\033[32m'     # 绿字 Green text
CYAN_WD='\033[36m'      # 青字 Cyan text
BLINK='\033[5m'         # 闪烁效果 Blinking effect
ITALIC='\033[3m'        # 斜体 Italic
LB='\033[2m'            # 低亮度 Low brightness
BOLD='\033[1m'          # 粗体 Bold
RESET='\033[0m'         # 重置格式 Reset style
DOWNLOAD_URL="$1"       # 下载链接 Download link
DOWNLOAD_FILENAME="$2"  # 保存文件名 Save file name
DOWNLOAD_DIR="${3:-.}"  # 保存路径,默认为工作目录 Save path, default to working directory
MAX_RETRY=3

surfing_progress_bar() {
	TMP_FILE="$(mktemp /tmp/surfing_curl.XXXXXX)"

	_clean_tmpfile() {
		rm -f $TMP_FILE
	}

	local _wave_animation_blocks="▁▂▃▄▅▆▇█▇▆▅▄▃▂▁▂▃▄▅▆▇█▇▆▅▄▃▂▁"

	_wave_animation() {
		local attempt=$1
		local -a positions=(0 -2 2)
		local -a directions=(1 -1 1)
		local line_buffer1 line_buffer2 buffer_switch=0
		tput civis

		while :; do
			core_line=""
			for ((i = 0; i < ${#_wave_animation_blocks}; i++)); do
				max_height=0
				for p in "${!positions[@]}"; do
					pos=${positions[p]}
					distance=$(((i - pos + ${#_wave_animation_blocks}) % ${#_wave_animation_blocks}))
					distance=$((distance > ${#_wave_animation_blocks} / 2 ? ${#_wave_animation_blocks} - distance : distance))
					((${#_wave_animation_blocks} - distance > max_height)) && max_height=$((${#_wave_animation_blocks} - distance))
				done

				index=$((max_height * ${#_wave_animation_blocks} / (${#_wave_animation_blocks} + 2)))
				((index >= ${#_wave_animation_blocks})) && index=$((${#_wave_animation_blocks} - 1))
				core_line+=${_wave_animation_blocks:index:1}
			done

			if [[ -f $TMP_FILE ]]; then
				read current_size speed < <(awk '{print $1,$2}' $TMP_FILE)
				info_text="已下载:$((current_size / 1024))kb 速度:$((speed / 1024))kbps"
			else
				info_text="正在初始化..."
			fi

			full_line=" Surfing:${CYAN_BG}[${core_line}]${RESET} ${info_text} 尝试下载(第 ${attempt} 次)"
			if ((buffer_switch)); then
				line_buffer2=$full_line
				echo -ne "\r\033[K$line_buffer1"
			else
				line_buffer1=$full_line
				echo -ne "\r\033[K$line_buffer2"
			fi
			((buffer_switch ^= 1))

			for p in "${!positions[@]}"; do
				(((positions[p] += directions[p]) > ${#_wave_animation_blocks} / 2 || positions[p] < -${#_wave_animation_blocks} / 2)) &&
					directions[p]=$((-directions[p]))
			done

			sleep 0.12
		done
	}

	# 处理用户中断 Handling user interrupts
	_surfing_progress_bar_cancel_loading() {
		local current_size=$(stat -c %s "$DOWNLOAD_DIR/$DOWNLOAD_FILENAME" 2>/dev/null || echo 0)
		echo -ne "\r\033[K ${BLINK}${CYAN_WD}[!]${RESET} 用户中断 ${ITALIC}${LB}${CYAN_WD}(已下载:$((current_size / 1024))kb)${RESET}\n"
		_clean_tmpfile
		rm -f $DOWNLOAD_DIR/$DOWNLOAD_FILENAME
		kill $(jobs -p) >/dev/null 2>&1
		tput cnorm
		exit 1
	}
	trap _surfing_progress_bar_cancel_loading SIGINT

	_surfing_progress_bar_real_progress_bar_retry_animation() {
		tput civis
		local counter=0
		local _wave_animation_blocks="▁▂▃▄▅▆▇█▇▆▅▄▃▂▁▂▃▄▅▆▇█▇▆▅▄▃▂▁"

		# 初始化退浪参数(3个波形中心点从分散到聚集)
		# Initialize wave receding parameters (3 waveform center points from scattered to clustered)
		local -a positions=(12 12 12) # 初始集中在中间位置 Initially concentrated in the middle position
		local -a directions=(-1 1 -1) # 运动方向改为收缩模式 Change the direction of motion to contraction mode

		while ((counter < 80)); do
			local core_line=""
			# 构建退浪核心(波形参数逆向计算)
			# Building a wave regression core (reverse calculation of waveform parameters)
			for ((i = 0; i < ${#_wave_animation_blocks}; i++)); do
				max_height=0
				for p in "${!positions[@]}"; do
					pos=${positions[p]}
					distance=$(((i - pos + ${#_wave_animation_blocks}) % ${#_wave_animation_blocks}))
					distance=$((distance > ${#_wave_animation_blocks} / 2 ? ${#_wave_animation_blocks} - distance : distance))
					((${#_wave_animation_blocks} - distance > max_height)) && max_height=$((${#_wave_animation_blocks} - distance))
				done

				# 高度衰减系数(随时间递减)
				# Height attenuation coefficient (decreasing over time)
				decay_factor=$((80 - counter))
				index=$(((max_height * decay_factor / 80) * ${#_wave_animation_blocks} / (${#_wave_animation_blocks} + 2)))
				((index >= ${#_wave_animation_blocks})) && index=$((${#_wave_animation_blocks} - 1))
				core_line+=${_wave_animation_blocks:index:1}
			done

			# 动态显示退浪效果 Dynamically display the anti wave effect
			remaining=$((4 - counter / 20))
			dots=$(((counter % 16) / 4)) # 每0.2秒增加一个点 Add one point every 0.2 seconds
			printf "\r\033[K Ebbing:${CYAN_BG}[%s]${RESET} 等待 %d 秒后重试%0.*s" "${core_line}" "${remaining}" ${dots} "...."

			# 更新波形中心点(产生收缩效果) Update the center point of the waveform (to produce a contraction effect)
			for p in "${!positions[@]}"; do
				((positions[p] += directions[p] * (80 - counter) / 20)) # 振幅逐渐缩小 The amplitude gradually decreases
				((positions[p] = (positions[p] + ${#_wave_animation_blocks}) % ${#_wave_animation_blocks}))
			done

			sleep 0.05
			((counter++))
		done
		tput cnorm
	}

	_wave_download() {
		local attempt=1

		while ((attempt <= MAX_RETRY)); do
			: >"$DOWNLOAD_DIR/$DOWNLOAD_FILENAME"
			echo "0 0" >$TMP_FILE

			(
				prev=0
				while [[ -f $TMP_FILE ]]; do
					if [[ -f "$DOWNLOAD_DIR/$DOWNLOAD_FILENAME" ]]; then
						current=$(stat -c %s "$DOWNLOAD_DIR/$DOWNLOAD_FILENAME")
						echo "$current $((current - prev))" >$TMP_FILE
						prev=$current
					else
						echo "0 0" >$TMP_FILE
					fi
					sleep 0.5
				done
			) &
			stat_pid=$!

			_wave_animation $attempt &
			_wave_animation_pid=$!
			disown

			if curl -s -o "$DOWNLOAD_DIR/$DOWNLOAD_FILENAME" "$DOWNLOAD_URL"; then
				kill $stat_pid $_wave_animation_pid >/dev/null 2>&1
				current_size=$(stat -c %s "$DOWNLOAD_DIR/$DOWNLOAD_FILENAME" 2>/dev/null || echo 0)
				printf "\r\033[K 下载完成 共计:%dkb\n" "$((current_size / 1024))"
				tput cnorm
				_clean_tmpfile
				return 0
			else
				kill $stat_pid $_wave_animation_pid >/dev/null 2>&1
				printf "\r\033[K 下载失败" "$_wave_animation_blocks"
				_clean_tmpfile
				rm -f $DOWNLOAD_DIR/$DOWNLOAD_FILENAME
				tput cnorm
				((attempt++))
				if ((attempt <= MAX_RETRY)); then
					_surfing_progress_bar_real_progress_bar_retry_animation
				fi
			fi
		done

		printf "\r\033[K已达最大重试次数\n" "$_wave_animation_blocks"
		_clean_tmpfile
		rm -f $DOWNLOAD_DIR/$DOWNLOAD_FILENAME
		return 1
	}

_wave_download
}

real_progress_bar() {
	# 进度控制变量 Progress control variables
	TOTAL_STEPS=10000  # 总步数,支持100.00%精度(每步0.01%) Total steps, supporting 100.00% accuracy (0.01% per step)
	CURRENT_PROGRESS=0 # 当前进度(0-10000) Current progress (0-10000)

	# 处理用户中断 Handling user interrupts
	_real_progress_bar_cancel_loading() {
		if [ $CURRENT_PROGRESS -le 3000 ]; then
			COLOR_WD="${RED_WD}${ITALIC}"
		elif [ $CURRENT_PROGRESS -le 7000 ]; then
			COLOR_WD="${YELLOW_WD}${ITALIC}"
		else
			COLOR_WD="${GREEN_WD}${ITALIC}"
		fi
		percent=$(printf "%5.2f" $(echo "scale=2; $CURRENT_PROGRESS / 100" | bc))
		echo -ne "\r\033[K${RED_WD}${BLINK} [!]${RESET} ${BOLD}用户中断${RESET} ${LB}${COLOR_WD}(进度:${percent}%)${RESET}\n"
		rm -f $DOWNLOAD_DIR/$DOWNLOAD_FILENAME
		tput cnorm
		exit 1
	}
	trap _real_progress_bar_cancel_loading SIGINT

	# 初始化进度条 Initialize progress bar
	_init_progress() {
		CURRENT_PROGRESS=0
		tput civis
	}

	# 更新进度条(修改为接受绝对进度值) Update progress bar (modified to accept absolute progress values)
	_update_progress() {
		local message="$1"          # 显示的消息 Displayed messages
		local current_progress="$2" # 当前进度(0-10000) Current progress (0-10000)

		CURRENT_PROGRESS=$current_progress

		# 确保进度不超过100% Ensure that the progress does not exceed 100%
		if [ $CURRENT_PROGRESS -gt $TOTAL_STEPS ]; then
			CURRENT_PROGRESS=$TOTAL_STEPS
		fi

		local percent=$(printf "%5.2f" $(echo "scale=2; $CURRENT_PROGRESS / 100" | bc))

		# 根据进度选择颜色 Select color based on progress
		if [ $CURRENT_PROGRESS -le 3000 ]; then
			COLOR_BG="${RED_BG}"
		elif [ $CURRENT_PROGRESS -le 7000 ]; then
			COLOR_BG="${YELLOW_BG}"
		else
			COLOR_BG="${GREEN_BG}"
		fi

		# 计算进度条填充(总长度29个字符) Fill the progress bar with a total length of 29 characters
		fille_real_progress_bar_retry_animationd=$(((CURRENT_PROGRESS * 29 + 5000) / 10000))
		bar=$(printf "[%-29s]" "$(printf "%${filled}s" | tr ' ' '#')")

		printf "\r Loading:%b%s${RESET} %6s%% %s\033[K" "$COLOR_BG" "$bar" "$percent" "$message"
	}

	# 完成进度条 Complete progress bar
	_finishpercent_progress() {
		local filled_bar=$(printf "[%-29s]" "$(printf "%29s" | tr ' ' '#')")
		printf "\r Loading:${GREEN_BG}%s${RESET} 100.00%% 下载完成\033[K\n" "$filled_bar"
		tput cnorm
	}

	# 重试动画 Retry animation
	_real_progress_bar_retry_animation() {
		tput civis
		local delay=0.05
		local counter=0
		local total=$((5 * 20)) # 5秒 * 20次/秒 = 100次 5 seconds * 20 times/second=100 times

		while ((counter < total)); do
			local remaining_sec=$((5 - counter / 20))
			local dot_phase=$(((counter / 8) % 4))
			local dots=$(printf "%${dot_phase}s" | tr ' ' '.')
			_update_progress "等待 ${remaining_sec} 秒后重试${dots}" 0
			sleep "$delay"
			((counter++))
		done
		printf "\r\033[K" # 清除最终行内容 Clear the final line content
		tput cnorm
	}

	# 主逻辑 Main logic
	_init_progress

	for attempt in $(seq 1 $MAX_RETRY); do
		CURRENT_PROGRESS=0

		# 执行curl并处理进度输出 Execute curl and process progress output
		while IFS= read -d $'\r' -r line; do
			percentage=$(echo "$line" | sed -n 's/.* \([0-9]\+\(\.[0-9]\+\)\?\)% *$/\1/p')
			if [ -n "$percentage" ]; then
				current_progress=$(echo "$percentage" | awk '{print int($1 * 100)}')
				_update_progress "尝试下载(第 $attempt 次)" "$current_progress"
			fi
		done < <(curl --progress-bar -o "$DOWNLOAD_DIR/$DOWNLOAD_FILENAME" "$DOWNLOAD_URL" 2>&1)

		# 检查下载是否成功 Check if the download was successful
		if [ $? -eq 0 ]; then
			_finishpercent_progress
			break
		else
			_update_progress "下载失败" 0
			rm -f $DOWNLOAD_DIE/$DOWNLOAD_FILENAME
			if [ $attempt -lt $MAX_RETRY ]; then
				_real_progress_bar_retry_animation
			else
				echo -e "\n达到最大重试次数,下载失败"
				rm -f $DOWNLOAD_DIR/$DOWNLOAD_FILENAME
				tput cnorm
				exit 1
			fi
		fi
	done
}

# 发送HEAD请求并提取Content-Length. Send HEAD request and extract Content Length
file_size=$(curl -sI "$DOWNLOAD_URL" | grep -i 'Content-Length' | awk '{print $2}' | tr -d '\r')

if [ -n "$file_size" ]; then
	real_progress_bar
else
	surfing_progress_bar
fi
