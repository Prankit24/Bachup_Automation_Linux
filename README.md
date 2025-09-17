# Bachup_Automation_Linux
	Tải git ( người dùng chưa có git):
sudo apt update
sudo apt install -y git
	Tải công cụ backup:
git clone https://github.com/Prankit24/Bachup_Automation_Linux.git
cd Bachup_Automation_Linux
	Đảm bảo công cụ trên nền tảng:
sudo apt update
sudo apt install -y bash tar gzip findutils coreutils
	Cấp quyền chạy:
 chmod +x src/backup.sh
	Thông báo Email:
-	Cài mailer: msmtp.
sudo apt update
sudo apt install -y msmtp msmtp-mta ca-certificates
