use std::env;
use std::fs;
use std::io::{self, Write};
use std::path::Path;
use std::process;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use reqwest;
use tokio;

// ANSI color codes
const RED_BG: &str = "\x1b[41;37m";     // Red background with white text
const YELLOW_BG: &str = "\x1b[43;34m";  // Yellow background with blue text
const GREEN_BG: &str = "\x1b[42;30m";   // Green background with black text
const CYAN_BG: &str = "\x1b[46;37m";    // Cyan background with white text
const RED_WD: &str = "\x1b[31m";        // Red text
const CYAN_WD: &str = "\x1b[36m";       // Cyan text
const BLINK: &str = "\x1b[5m";          // Blinking effect
const ITALIC: &str = "\x1b[3m";         // Italic
const LB: &str = "\x1b[2m";             // Low brightness
const BOLD: &str = "\x1b[1m";           // Bold
const RESET: &str = "\x1b[0m";          // Reset style

const MAX_RETRY: u32 = 3;

struct DownloadProgress {
    current_size: Arc<AtomicU64>,
    speed: Arc<AtomicU64>,
    is_running: Arc<AtomicBool>,
}

impl DownloadProgress {
    fn new() -> Self {
        Self {
            current_size: Arc::new(AtomicU64::new(0)),
            speed: Arc::new(AtomicU64::new(0)),
            is_running: Arc::new(AtomicBool::new(true)),
        }
    }
}

fn hide_cursor() {
    print!("\x1b[?25l");
    io::stdout().flush().unwrap();
}

fn show_cursor() {
    print!("\x1b[?25h");
    io::stdout().flush().unwrap();
}

fn clear_line() {
    print!("\r\x1b[K");
    io::stdout().flush().unwrap();
}

async fn get_content_length(url: &str) -> Option<u64> {
    let client = reqwest::Client::new();
    match client.head(url).send().await {
        Ok(response) => response.content_length(),
        Err(_) => None,
    }
}

fn surfing_progress_bar(url: &str, filename: &str, download_dir: &str) -> Result<(), Box<dyn std::error::Error>> {
    let wave_blocks = "▁▂▃▄▅▆▇█▇▆▅▄▃▂▁▂▃▄▅▆▇█▇▆▅▄▃▂▁";
    let progress = DownloadProgress::new();
    
    // Setup Ctrl+C handler
    let _is_running = progress.is_running.clone();
    let download_path = format!("{}/{}", download_dir, filename);
    let path_for_cleanup = download_path.clone();
    
    ctrlc::set_handler(move || {
        let current_size = match fs::metadata(&path_for_cleanup) {
            Ok(metadata) => metadata.len(),
            Err(_) => 0,
        };
        
        clear_line();
        println!(" {}{}[!]{} 用户中断 {}{}{}(已下载:{}kb){}",
            BLINK, CYAN_WD, RESET, ITALIC, LB, CYAN_WD, current_size / 1024, RESET);
        
        let _ = fs::remove_file(&path_for_cleanup);
        show_cursor();
        process::exit(1);
    }).expect("Error setting Ctrl-C handler");

    let mut attempt = 1;
    
    while attempt <= MAX_RETRY {
        progress.current_size.store(0, Ordering::Relaxed);
        progress.speed.store(0, Ordering::Relaxed);
        progress.is_running.store(true, Ordering::Relaxed);
        
        // Start wave animation
        let progress_clone = DownloadProgress {
            current_size: progress.current_size.clone(),
            speed: progress.speed.clone(),
            is_running: progress.is_running.clone(),
        };
        
        let wave_handle = thread::spawn(move || {
            wave_animation(wave_blocks, attempt, progress_clone);
        });
        
        // Start download monitoring
        let current_size = progress.current_size.clone();
        let speed = progress.speed.clone();
        let is_running = progress.is_running.clone();
        let monitor_path = download_path.clone();
        
        let monitor_handle = thread::spawn(move || {
            let mut prev_size = 0u64;
            while is_running.load(Ordering::Relaxed) {
                let current = match fs::metadata(&monitor_path) {
                    Ok(metadata) => metadata.len(),
                    Err(_) => 0,
                };
                
                let speed_val = if current > prev_size { current - prev_size } else { 0 };
                current_size.store(current, Ordering::Relaxed);
                speed.store(speed_val * 2, Ordering::Relaxed); // *2 because we check every 0.5s
                prev_size = current;
                
                thread::sleep(Duration::from_millis(500));
            }
        });
        
        // Perform download
        let rt = tokio::runtime::Runtime::new().unwrap();
        let download_result = rt.block_on(async {
            download_file(url, &download_path).await
        });
        
        // Stop monitoring and animation
        progress.is_running.store(false, Ordering::Relaxed);
        let _ = wave_handle.join();
        let _ = monitor_handle.join();
        
        match download_result {
            Ok(_) => {
                let current_size = match fs::metadata(&download_path) {
                    Ok(metadata) => metadata.len(),
                    Err(_) => 0,
                };
                clear_line();
                println!(" 下载完成 共计:{}kb", current_size / 1024);
                show_cursor();
                return Ok(());
            }
            Err(_) => {
                clear_line();
                print!(" 下载失败");
                io::stdout().flush().unwrap();
                let _ = fs::remove_file(&download_path);
                show_cursor();
                
                attempt += 1;
                if attempt <= MAX_RETRY {
                    retry_animation();
                }
            }
        }
    }
    
    clear_line();
    println!("已达最大重试次数");
    let _ = fs::remove_file(&download_path);
    Err("Max retries exceeded".into())
}

fn wave_animation(wave_blocks: &str, attempt: u32, progress: DownloadProgress) {
    let blocks: Vec<char> = wave_blocks.chars().collect();
    let mut positions = vec![0i32, -2, 2];
    let directions = vec![1i32, -1, 1]; // 移除了多余的 mut
    let mut buffer_switch = false;
    let mut line_buffer1 = String::new();
    let mut line_buffer2 = String::new();
    
    hide_cursor();
    
    while progress.is_running.load(Ordering::Relaxed) {
        let mut core_line = String::new();
        
        for i in 0..blocks.len() {
            let mut max_height = 0;
            
            for pos in &positions {
                let distance = ((i as i32 - pos + blocks.len() as i32) % blocks.len() as i32).abs();
                let distance = if distance > blocks.len() as i32 / 2 {
                    blocks.len() as i32 - distance
                } else {
                    distance
                };
                
                let height = blocks.len() as i32 - distance;
                if height > max_height {
                    max_height = height;
                }
            }
            
            let mut index = (max_height * blocks.len() as i32 / (blocks.len() as i32 + 2)) as usize;
            if index >= blocks.len() {
                index = blocks.len() - 1;
            }
            core_line.push(blocks[index]);
        }
        
        let current_size = progress.current_size.load(Ordering::Relaxed);
        let speed = progress.speed.load(Ordering::Relaxed);
        let info_text = if current_size > 0 || speed > 0 {
            format!("已下载:{}kb 速度:{}kbps", current_size / 1024, speed / 1024)
        } else {
            "正在初始化...".to_string()
        };
        
        let full_line = format!(" Surfing:{}[{}]{} {} 尝试下载(第 {} 次)",
            CYAN_BG, core_line, RESET, info_text, attempt);
        
        if buffer_switch {
            line_buffer2 = full_line;
            print!("\r\x1b[K{}", line_buffer1);
        } else {
            line_buffer1 = full_line;
            print!("\r\x1b[K{}", line_buffer2);
        }
        io::stdout().flush().unwrap();
        buffer_switch = !buffer_switch;
        
        // Update positions
        for i in 0..positions.len() {
            positions[i] += directions[i];
            if positions[i] > blocks.len() as i32 / 2 || positions[i] < -(blocks.len() as i32 / 2) {
            }
        }
        
        thread::sleep(Duration::from_millis(120));
    }
}

fn retry_animation() {
    hide_cursor();
    let wave_blocks = "▁▂▃▄▅▆▇█▇▆▅▄▃▂▁▂▃▄▅▆▇█▇▆▅▄▃▂▁";
    let blocks: Vec<char> = wave_blocks.chars().collect();
    let mut positions = vec![12i32, 12, 12];
    let directions = vec![-1i32, 1, -1]; // 移除了多余的 mut
    
    for counter in 0..80 {
        let mut core_line = String::new();
        
        for i in 0..blocks.len() {
            let mut max_height = 0;
            
            for pos in &positions {
                let distance = ((i as i32 - pos + blocks.len() as i32) % blocks.len() as i32).abs();
                let distance = if distance > blocks.len() as i32 / 2 {
                    blocks.len() as i32 - distance
                } else {
                    distance
                };
                
                let height = blocks.len() as i32 - distance;
                if height > max_height {
                    max_height = height;
                }
            }
            
            let decay_factor = 80 - counter;
            let mut index = ((max_height * decay_factor / 80) * blocks.len() as i32 / (blocks.len() as i32 + 2)) as usize;
            if index >= blocks.len() {
                index = blocks.len() - 1;
            }
            core_line.push(blocks[index]);
        }
        
        let remaining = 4 - counter / 20;
        let dots = (counter % 16) / 4;
        // 修复类型错误：将i32转换为usize
        let dot_string = ".".repeat(dots as usize);
        
        print!("\r\x1b[K Ebbing:{}[{}]{} 等待 {} 秒后重试{}",
            CYAN_BG, core_line, RESET, remaining, dot_string);
        io::stdout().flush().unwrap();
        
        // Update positions
        for i in 0..positions.len() {
            positions[i] += directions[i] * (80 - counter) / 20;
            positions[i] = (positions[i] + blocks.len() as i32) % blocks.len() as i32;
        }
        
        thread::sleep(Duration::from_millis(50));
    }
    show_cursor();
}

fn real_progress_bar(url: &str, filename: &str, download_dir: &str) -> Result<(), Box<dyn std::error::Error>> {
    let download_path = format!("{}/{}", download_dir, filename);
    let path_for_cleanup = download_path.clone();
    
    // Setup Ctrl+C handler
    ctrlc::set_handler(move || {
        clear_line();
        println!("{}{}[!]{} {}用户中断{} {}{}{}(进度:未知){}",
            RED_WD, BLINK, RESET, BOLD, RESET, LB, ITALIC, RED_WD, RESET);
        let _ = fs::remove_file(&path_for_cleanup);
        show_cursor();
        process::exit(1);
    }).expect("Error setting Ctrl-C handler");
    
    hide_cursor();
    
    for attempt in 1..=MAX_RETRY {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let result = rt.block_on(async {
            download_file_with_progress(url, &download_path, attempt).await
        });
        
        match result {
            Ok(_) => {
                let filled_bar = "#".repeat(29);
                clear_line();
                println!(" Loading:{}[{}]{} 100.00% 下载完成", GREEN_BG, filled_bar, RESET);
                show_cursor();
                return Ok(());
            }
            Err(_) => {
                update_progress("下载失败", 0);
                let _ = fs::remove_file(&download_path);
                
                if attempt < MAX_RETRY {
                    real_progress_bar_retry_animation();
                } else {
                    println!("\n达到最大重试次数,下载失败");
                    let _ = fs::remove_file(&download_path);
                    show_cursor();
                    return Err("Max retries exceeded".into());
                }
            }
        }
    }
    
    Ok(())
}

fn update_progress(message: &str, progress: u32) {
    let progress = if progress > 10000 { 10000 } else { progress };
    let percent = progress as f64 / 100.0;
    
    let color_bg = if progress <= 3000 {
        RED_BG
    } else if progress <= 7000 {
        YELLOW_BG
    } else {
        GREEN_BG
    };
    
    let filled = ((progress * 29 + 5000) / 10000) as usize;
    let bar = format!("[{:29}]", "#".repeat(filled));
    
    print!("\r Loading:{}{}{} {:6.2}% {}\x1b[K", color_bg, bar, RESET, percent, message);
    io::stdout().flush().unwrap();
}

fn real_progress_bar_retry_animation() {
    hide_cursor();
    let total = 5 * 20; // 5 seconds * 20 times/second = 100 times
    
    for counter in 0..total {
        let remaining_sec = 5 - counter / 20;
        let dot_phase = (counter / 8) % 4;
        let dots = ".".repeat(dot_phase);
        update_progress(&format!("等待 {} 秒后重试{}", remaining_sec, dots), 0);
        thread::sleep(Duration::from_millis(50));
    }
    
    clear_line();
    show_cursor();
}

async fn download_file(url: &str, path: &str) -> Result<(), Box<dyn std::error::Error>> {
    let response = reqwest::get(url).await?;
    let bytes = response.bytes().await?;
    tokio::fs::write(path, bytes).await?;
    Ok(())
}

async fn download_file_with_progress(url: &str, path: &str, attempt: u32) -> Result<(), Box<dyn std::error::Error>> {
    let client = reqwest::Client::new();
    let mut response = client.get(url).send().await?;
    
    let total_size = response.content_length().unwrap_or(0);
    let mut downloaded = 0u64;
    let mut file = tokio::fs::File::create(path).await?;
    
    while let Some(chunk) = response.chunk().await? {
        use tokio::io::AsyncWriteExt;
        file.write_all(&chunk).await?;
        downloaded += chunk.len() as u64;
        
        if total_size > 0 {
            let progress = ((downloaded * 10000) / total_size) as u32;
            update_progress(&format!("尝试下载(第 {} 次)", attempt), progress);
        }
    }
    
    Ok(())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    
    if args.len() < 3 {
        println!("使用方法: {} <下载URL> <文件名> [保存路径]", args[0]);
        process::exit(1);
    }
    
    let download_url = &args[1];
    let download_filename = &args[2];
    let download_dir = args.get(3).map(|s| s.as_str()).unwrap_or(".");
    
    // Create download directory if it doesn't exist
    if !Path::new(download_dir).exists() {
        fs::create_dir_all(download_dir)?;
    }
    
    // Check if server supports content-length
    let file_size = get_content_length(download_url).await;
    
    if file_size.is_some() {
        real_progress_bar(download_url, download_filename, download_dir)?;
    } else {
        surfing_progress_bar(download_url, download_filename, download_dir)?;
    }
    
    Ok(())
}
