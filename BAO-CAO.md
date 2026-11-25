# Báo cáo đồ án Oracle RAC 19c

## Mục tiêu

Dựng một cụm Oracle RAC ban đầu có một instance phục vụ ứng dụng. Sau đó thêm instance thứ hai trong lúc ứng dụng gửi giao dịch, kiểm chứng đọc chéo, thử cắt nguồn một VM và xác minh node tái gia nhập cụm.

## Môi trường và kiến trúc

| Thành phần | Cấu hình |
| --- | --- |
| Host | Ubuntu 24.04.5 LTS, Intel i5-14600KF, 18 CPU logic, 27 GiB RAM |
| Ảo hóa | QEMU/KVM và libvirt. QMP xác nhận KVM hoạt động |
| Hai guest | Oracle Linux 7.9, RHCK `3.10.0-1160.el7.x86_64`, mỗi VM 4 vCPU, 9 GiB RAM và đĩa OS QCOW2 80 GiB |
| Mạng | Mạng client NAT `192.168.191.0/24` và interconnect riêng `192.168.192.0/24` |
| Oracle | Grid Infrastructure và Oracle Database Enterprise Edition 19.3. Database `RACLAB`, PDB `APPPDB`, service `racapp.rac.test` |
| Lưu trữ | Hai guest cùng truy cập một file raw 60 GiB qua `/dev/rac-asm01`. ASM disk group `+DATA` dùng external redundancy và chứa voting disk |
| Client | Python chạy trên host qua SCAN `rac-scan.rac.test` |

ISO Oracle Linux và hai ZIP Oracle 19.3 khớp SHA-256 chính thức. Lab dùng `oracle-database-preinstall-19c` từ kho Yum công khai, `cvuqdisk` từ Grid Home và CVU để kiểm tra hai node. [Yêu cầu Oracle Linux 7 cho Oracle Database 19c](https://docs.oracle.com/en/database/oracle/oracle-database/19/lacli/operating-system-requirements-for-x86-64-linux-platforms/supported-oracle-linux-7-distributions-for-x86-64.html) · [Yêu cầu phần cứng Grid Infrastructure](https://docs.oracle.com/en/database/oracle/oracle-database/19/cwlin/server-hardware-checklist-for-oracle-grid-infrastructure.html)

## Kết quả thực nghiệm

Thử nghiệm thực hiện ngày 25/11/2026. Các mốc dưới đây dùng giờ Việt Nam.

| Mốc | Bằng chứng quan sát |
| --- | --- |
| Cụm một node, 09:32 | `olsnodes` chỉ có `rac1`. `cluster_database=TRUE`, `APPPDB` mở `READ WRITE`. Client trên host commit request `1c326e8f-7351-40ac-90f9-d56169bf1edf` trên `RACLAB1` qua SCAN và application service. |
| Thêm node, 09:58–10:06 | `olsnodes` báo cả hai node `Active`. CVU sau khi thêm node thành công. DBCA thêm `RACLAB2` và `gv$instance` hiển thị hai instance `OPEN`. Dòng ghi qua service trong các đoạn trước và sau khi tiếp tục bước CVU xác nhận giao dịch trên cả hai instance. |
| Đọc chéo, 10:07 | `RACLAB1` commit request `2e7733ff-0725-45c6-a27b-bc8714859a39`. `RACLAB2` đọc lại cùng request ID và đúng payload qua cùng service. |
| Cắt nguồn ảo, 10:07–10:08 | Sau khi đối chiếu UUID VM và instance của client, libvirt cắt nguồn `rac1`. Client nhận `DPY-4011`, kết nối lại qua cùng SCAN và commit trên `RACLAB2`. |
| Tái gia nhập, 10:10 | Sau khi bật lại `rac1`, Clusterware khởi động lại `RACLAB1`. Hai instance mở, service chạy trên cả hai. |
| Đối soát | Tìm thấy đủ 972 trong 972 request của lượt demo. Số bản ghi thiếu, trùng, sai payload và request chưa xác định đều bằng 0. |
| Kiểm tra cuối, 10:37 | Cả hai node `Active`. 12 kết nối xác minh đi vào đủ hai instance. Client commit thêm một request qua service sau benchmark. |

Trước khi thêm node, lab dừng database, Clusterware và cả hai VM để sao hai đĩa hệ điều hành, đĩa ASM và XML cấu hình ở cùng trạng thái. Kiểm tra ảnh QCOW2 và tạo manifest SHA-256 trước khi tiếp tục.

## Phương pháp đo

So sánh service phục vụ trên một và hai instance. Giữ cả hai VM hoạt động, dùng cùng 12 worker, mẫu payload và bảng thử được truncate trước mỗi lượt. Cấu hình hai instance khởi tạo sáu phiên trên mỗi instance qua cùng service. Mỗi cấu hình có ba lượt hợp lệ, với 60 giây warm-up và 180 giây đo mỗi lượt. Đảo thứ tự cấu hình ở lượt giữa.

Thu TPS, p50/p95, tỷ lệ request gặp lỗi, phân bố giao dịch, RAM, swap và I/O host. Đo thời gian phục hồi bằng đồng hồ monotonic trên host, từ lúc lệnh cắt nguồn được xác nhận đến commit thành công tiếp theo của client bị ảnh hưởng. Dùng khóa chính `request_id` để tra lại kết quả khi client mất xác nhận commit.

### Xác minh các lượt benchmark

| Cấu hình service | Lượt hoàn tất | Instance phục vụ được xác nhận trong từng lượt |
| --- | --- | --- |
| Một instance | 3/3 | `RACLAB1` ở cả ba lượt |
| Hai instance | 3/3 | `RACLAB1` và `RACLAB2` ở cả ba lượt |

Mỗi lượt được chấp nhận khi dùng đủ 12 worker, warm-up 60 giây, đo 180 giây và có giao dịch trên đúng các instance dự kiến. Sau lượt cuối, service trở lại cả hai instance và client trên host đã commit thêm một giao dịch qua SCAN.

Số đo và biểu đồ hiệu năng được lưu trong báo cáo nội bộ. Điều khoản OTN Developer yêu cầu Oracle đồng ý trước khi công bố kết quả benchmark. [Oracle Technology Network Developer License Terms](https://www.oracle.com/downloads/licenses/standard-license.html)

## Giới hạn và kết luận

Thử nghiệm xác nhận database tiếp tục phục vụ giao dịch khi mất nguồn một VM, và node cũ tiếp tục phục vụ sau khi tái gia nhập. Host vật lý và file ASM là điểm lỗi chung của mô hình. Kết quả áp dụng cho sự cố một VM trong lab này.
