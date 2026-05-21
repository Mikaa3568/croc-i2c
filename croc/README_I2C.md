# I2C Master Controller — Croc SoC Integration

Tài liệu này mô tả toàn bộ quá trình tích hợp, thông số kỹ thuật và các bước chạy của
module **I2C Master Controller** trong dự án `croc_i2c`.

---

## 1. Tổng quan

Module I2C Master được tích hợp vào `user_domain` của Croc SoC thông qua bus **OBI**.
Phần mềm trên lõi CVE2 (RISC-V) truy cập module thông qua memory-mapped registers
tại địa chỉ `0x2000_0000`.

### Vị trí trong hierarchy

```
croc_chip  (top-level)
└── croc_soc
    └── user_domain   (i_user)
        └── i2c       (i_i2c)
            ├── i2c_clkgen   (i_clkgen)  — bộ tạo xung SCL
            ├── i2c_ctrl     (i_ctrl)    — FSM bit-level
            └── i2c_regif    (i_regif)   — OBI register interface
```

---

## 2. Chân tín hiệu (Ports)

### 2.1 Chân vật lý ra ngoài chip

Chip top-level dùng **bidirectional pad** (`sg13g2_IOPadInOut30mA`):

| Chân chip | Kiểu | Mô tả |
|-----------|------|-------|
| `i2c_sda_io` | `inout wire` | Dữ liệu I2C (nối điện trở pull-up ~4.7 kΩ lên VDD) |
| `i2c_scl_io` | `inout wire` | Clock I2C (nối điện trở pull-up ~4.7 kΩ lên VDD) |

### 2.2 Tín hiệu nội bộ (bên trong croc_chip)

Mỗi pad được tách thành 3 tín hiệu nội bộ theo mô hình **open-drain**:

```
i2c_sda_io (pad)
    ├── .p2c  →  soc_i2c_sda_i   [input]   SDA đọc từ pad
    ├── .c2p  ←  soc_i2c_sda_o   [output]  luôn = 1'b0
    └── .c2p_en ← soc_i2c_sda_oe [output]  1=kéo SDA xuống LOW, 0=thả ra

i2c_scl_io (pad)
    ├── .p2c  →  soc_i2c_scl_i   [input]   SCL đọc từ pad
    ├── .c2p  ←  soc_i2c_scl_o   [output]  luôn = 1'b0
    └── .c2p_en ← soc_i2c_scl_oe [output]  1=kéo SCL xuống LOW, 0=thả ra
```

**Nguyên tắc open-drain:**
- `*_oe = 1` → module kéo đường xuống **LOW** (drive 0)
- `*_oe = 0` → module thả đường ra (high-Z), điện trở pull-up kéo lên **HIGH**

### 2.3 Port của module `i2c`

| Port | Hướng | Mô tả |
|------|-------|-------|
| `clk_i` | input | Clock hệ thống |
| `rst_ni` | input | Reset active-low bất đồng bộ |
| `i2c_sda_i` | input | SDA từ pad |
| `i2c_sda_o` | output | SDA tới pad (luôn 0) |
| `i2c_sda_oe` | output | Output enable SDA |
| `i2c_scl_i` | input | SCL từ pad |
| `i2c_scl_o` | output | SCL tới pad (luôn 0) |
| `i2c_scl_oe` | output | Output enable SCL |
| `obi_req_i` | input | OBI request từ SoC |
| `obi_rsp_o` | output | OBI response về SoC |

---

## 3. Thanh ghi (Register Map)

**Base address:** `0x2000_0000`

Thanh ghi được truy cập bằng từ 32-bit. Địa chỉ được giải mã theo `addr[4:1]`
nên bước nhảy giữa các thanh ghi là **4 byte**.

| Offset | Tên | R/W | Bits | Mô tả |
|--------|-----|-----|------|-------|
| `0x00` | `PRESCALER_LO` | R/W | [7:0] | Byte thấp của bộ chia xung SCL |
| `0x04` | `PRESCALER_HI` | R/W | [7:0] | Byte cao của bộ chia xung SCL |
| `0x08` | `CTR` | R/W | [7]=EN, [6]=IEN | Điều khiển lõi |
| `0x0C` | `TXR` | W (R=readback) | [7:0] | Dữ liệu truyền đi (địa chỉ slave hoặc data) |
| `0x10` | `CR` (write) | W | [7:0] | Lệnh điều khiển (START/STOP/WR/RD/ACK/IACK) |
| `0x10` | `RXR` (read) | R | [7:0] | Dữ liệu nhận được từ slave |
| `0x14` | `SR` | R | [7:0] | Thanh ghi trạng thái |

### Chi tiết bit CTR (`0x08`)

| Bit | Tên | Mô tả |
|-----|-----|-------|
| 7 | `EN` | Bật lõi I2C (phải set = 1 trước khi dùng) |
| 6 | `IEN` | Bật ngắt khi hoàn thành byte |

### Chi tiết bit CR (`0x10` — write)

| Bit | Tên | Mô tả |
|-----|-----|-------|
| 7 | `STA` | Phát điều kiện START |
| 6 | `STO` | Phát điều kiện STOP |
| 5 | `RD` | Đọc 1 byte từ slave |
| 4 | `WR` | Ghi 1 byte lên slave |
| 3 | `ACK` | 0 = gửi ACK, 1 = gửi NACK (khi đọc) |
| 0 | `IACK` | Xác nhận ngắt (xóa cờ IF) |

### Chi tiết bit SR (`0x14` — read)

| Bit | Tên | Mô tả |
|-----|-----|-------|
| 7 | `RxACK` | ACK từ slave: 0 = ACK (OK), 1 = NACK |
| 6 | `BUSY` | Bus đang bận (giữa START và STOP) |
| 5 | `AL` | Arbitration Lost |
| 1 | `TIP` | Transfer In Progress (đang truyền) |
| 0 | `IF` | Interrupt Flag: byte hoàn thành |

---

## 4. Clock và Timing

### 4.1 Công thức tính tần số SCL

```
SCL_frequency = clk_frequency / (2 * (prescaler + 1))
```

| Trường hợp | clk | prescaler | SCL |
|------------|-----|-----------|-----|
| Simulation (TB) | 20 MHz | 99 (0x63) | 100 kHz |
| Simulation (TB) | 20 MHz | 39 (0x27) | 250 kHz |
| Real silicon (Nominal) | 50 MHz | 249 (0xF9) | 100 kHz |
| Real silicon (Nominal) | 50 MHz | 61 (0x3D) | 400 kHz |
| Real silicon (STA Target) | 66.6 MHz | 332 (0x14C) | 100 kHz |
| Real silicon (STA Target) | 66.6 MHz | 82 (0x52) | 400 kHz |

**Giá trị mặc định sau reset:** `prescaler = 0x00F9` (249) → Tương đương 100 kHz tại clock 50 MHz (hoặc ~133 kHz tại clock 66.6 MHz).

### 4.2 Chu kỳ truyền 1 byte (8 bit + 1 ACK = 9 SCL cycles)

```
T_byte = 9 * T_SCL = 9 / SCL_frequency

Ví dụ tại 100 kHz:
  T_SCL  =  10 µs
  T_byte =  90 µs
  3 bytes (địa chỉ + 2 data) = ~270 µs
```

### 4.3 Dạng sóng một giao dịch WRITE

```
SDA: ‾‾\__[A7][A6][A5][A4][A3][A2][A1][RW=0][ACK][D7]...[D0][ACK]/‾‾
SCL:     ‾  ‾‾__‾‾__‾‾__‾‾__‾‾__‾‾__‾‾__‾‾__‾‾__  ‾‾__...‾‾__‾‾__  ‾
         START   ←──── địa chỉ slave ────────────→     ←── data ──→  STOP
```

- **START:** SDA xuống LOW khi SCL đang HIGH
- **Data bits:** SDA thay đổi khi SCL = LOW, slave/master lấy mẫu khi SCL = HIGH
- **ACK:** Sau 8 bit, slave kéo SDA xuống LOW (ACK) hoặc thả ra (NACK)
- **STOP:** SDA lên HIGH khi SCL đang HIGH

---

## 5. Thống kê thiết kế vật lý (Physical Design Report)

Kết quả từ OpenROAD sau synthesis + place & route (IHP SG13G2 130nm) cho top-level `croc_chip`. Thiết kế đã hoàn toàn sạch DRC (Clean) sau quá trình tối ưu hóa constraints và physical layout.

### 5.1 Đánh giá Timing (Timing Metrics)

Hệ thống hoạt động ổn định và đáp ứng tất cả các ràng buộc về thời gian (tại góc ff/tt):

| Thông số | Giá trị | Trạng thái |
|----------|---------|------------|
| Worst Slack Max (Setup) | **0.71 ns** | Đạt (MET) |
| Worst Slack Min (Hold) | **0.08 ns** | Đạt (MET) |
| Setup Violations | **0** | Pass |
| Hold Violations | **0** | Pass |

### 5.2 Kiểm tra Design Rule (DRV Violations)

Nhờ việc tối ưu hóa parameters của `repair_design` và thuật toán routing, các vi phạm về tính toàn vẹn tín hiệu (Signal Integrity) đã được khắc phục triệt để:

| Loại Violation | Số lượng | Trạng thái |
|----------------|----------|------------|
| Max Capacitance | **0** | Clean |
| Max Slew | **0** | Clean |
| Max Fanout | **0** | Clean |

### 5.3 Thông số Diện tích và Đi dây (Area & Routing)

| Thông số | Giá trị | Ghi chú |
|----------|---------|---------|
| Die Area (Kích thước Chip) | **3,671,056 µm²** | Tương đương ≈ 1.916 mm × 1.916 mm |
| Core Area | **1,571,082 µm²** | Khu vực chứa cell thực tế |
| Diện tích khối I2C (`i_i2c`) | **9,275 µm²** | Chiếm ~0.59% tổng diện tích Core |
| Tổng chiều dài đi dây | **1,886,141 µm** | ≈ 1.886 mét dây dẫn trên các lớp Metal |

### 5.4 Phân tích Công suất (Power Analysis)

Mức tiêu thụ năng lượng được phân bổ (tại góc Typical `tt`, 1.2V):

- **Tổng công suất tiêu thụ (Total Power):** **39.5 mW** (100%)
- **Mạng lưới Clock (Clock Power):** **13.9 mW** (35.1%) - *Phân phối xung nhịp toàn chip*
- **Bộ nhớ (Macro Power):** **8.46 mW** (21.4%) - *Từ các khối SRAM*
- **Logic tuần tự (Sequential):** **15.6 mW** (39.4%)
- **Logic tổ hợp (Combinational):** **1.11 mW** (2.8%)
- **Các Pad I/O (Pad Power):** **0.54 mW** (1.4%)

---

## 6. Các bước chạy dự án

### Bước 0: Chuẩn bị môi trường

```bash
# Clone repository
git clone <repo_url> croc_i2c
cd croc_i2c/croc

# Khởi động Docker container (IHP PDK + toolchain)
./scripts/start_linux.sh
# Từ đây tất cả lệnh bên dưới chạy TRONG Docker tại /fosic/designs/croc
```

### Bước 1: Build phần mềm (RISC-V cross-compile)

```bash
cd /fosic/designs/croc/sw

# Build tất cả chương trình (helloworld + tests)
make clean && make all

# File quan trọng được tạo ra:
#   bin/helloworld.hex          — chương trình demo
#   bin/test/test_i2c.hex       — test I2C gửi "HELLO"
```

### Bước 2: Chạy simulation Verilator (kiểm tra RTL)

```bash
cd /fosic/designs/croc/verilator

# Build + chạy với helloworld
./run_verilator.sh --build --run ../sw/bin/helloworld.hex

# Build + chạy test I2C (xem xung SCL/SDA trong GTKWave)
./run_verilator.sh --build --run ../sw/bin/test/test_i2c.hex

# Mở GTKWave để xem dạng sóng
gtkwave croc.fst &
# Tìm và thêm: tb_croc_soc.i2c_scl_i, i2c_scl_oe, i2c_sda_i, i2c_sda_oe
```

**Kết quả mong đợi trong terminal:**
```
[UART] I2C HELLO slow
[I2C Slave] Nhận được Address: 0xa0 (R/W: WRITE)
[I2C Slave] Nhận được Data: 0x47 (Ký tự: 'G')
[I2C Slave] Nhận được Data: 0x52 (Ký tự: 'R')
[I2C Slave] Nhận được Data: 0x4f (Ký tự: 'O')
[I2C Slave] Nhận được Data: 0x55 (Ký tự: 'U')
[I2C Slave] Nhận được Data: 0x50 (Ký tự: 'P')
[I2C Slave] Nhận được Data: 0x31 (Ký tự: '1')
[I2C Slave] Nhận được Data: 0x32 (Ký tự: '2')
[I2C Slave] Nhận được Address: 0xa1 (R/W:  READ)
[I2C Slave] TX OK:   sent 'h' (0x68) ✓
[UART] READ[0] from slave: 'h' (0x68)
[I2C Slave] Nhận được Address: 0xa1 (R/W:  READ)
[I2C Slave] TX OK:   sent 'e' (0x65) ✓
[UART] READ[1] from slave: 'e' (0x65)
[I2C Slave] Nhận được Address: 0xa1 (R/W:  READ)
[I2C Slave] TX OK:   sent 'l' (0x6c) ✓
[UART] READ[2] from slave: 'l' (0x6c)
[I2C Slave] Nhận được Address: 0xa1 (R/W:  READ)
[I2C Slave] TX OK:   sent 'l' (0x6c) ✓
[UART] READ[3] from slave: 'l' (0x6c)
[UART] DONE
```

**Kết quả mong đợi trong GTKWave:**
- I2C truyền ở chế độ **Continuous Write** (Multi-byte).
- Trọng tâm chú ý vào tín hiệu `i2c_sda_i` (tín hiệu vật lý thật).
- Sẽ thấy 1 vùng burst kéo dài liên tục chứa đủ 6 byte (1 byte địa chỉ + 5 byte data).
- Tại mỗi bit thứ 9, Dummy Slave sẽ kéo đường `i2c_sda_i` xuống 0 để báo **ACK**.

### Bước 3: Synthesis với Yosys

```bash
cd /fosic/designs/croc/yosys

# Tổng hợp RTL → netlist
./run_synthesis.sh --synth

# File quan trọng được tạo ra:
#   out/croc.v           — synthesized netlist
#   reports/area.rpt     — thống kê area sau synthesis
```

### Bước 4: Physical Backend với OpenROAD

```bash
cd /fosic/designs/croc/openroad

# Chạy toàn bộ flow (floorplan → place → CTS → route → finishing)
./run_backend.sh --all

# Hoặc chạy từng bước:
./run_backend.sh --step floorplan    # 01_floorplan.tcl
./run_backend.sh --step place        # 02_place.tcl
./run_backend.sh --step cts          # 03_cts.tcl
./run_backend.sh --step route        # 04_route.tcl
./run_backend.sh --step finishing    # 05_finishing.tcl
```

**Reports được tạo ra:**
```
openroad/reports/
├── 01-05_croc_area_hierarchical.rpt   ← area theo hierarchy (có I2C pin summary)
├── 02_croc.placed.rpt                 ← timing sau placement
├── 05_croc.final.rpt                  ← timing + area final
└── 05_croc.final.png                  ← layout image
```

### Bước 5: Kiểm tra kết quả

```bash
# Xem area report (có section I2C)
cat reports/01-05_croc_area_hierarchical.rpt | grep -A20 "i_i2c"

# Xem timing report
cat reports/05_croc.final.rpt | grep -A5 "WNS\|TNS"

# Mở layout trong OpenROAD GUI
openroad -gui
# load_checkpoint "07_croc.final"
```

---

## 7. Cấu trúc file

```
croc/
├── rtl/
│   ├── i2c/
│   │   ├── i2c_clkgen.sv       ← Bộ tạo xung SCL
│   │   ├── i2c_ctrl.sv         ← FSM điều khiển giao thức I2C
│   │   ├── i2c_regif.sv        ← Giao tiếp OBI và thanh ghi
│   │   ├── i2c.sv              ← I2C master top wrapper
│   │   └── i2c_reg_pkg.sv      ← Register package definitions
│   ├── user_domain.sv          ← Kết nối i_i2c vào OBI demux
│   └── croc_chip.sv            ← Kết nối pad inout với soc_i2c_* signals
├── sw/
│   ├── config.h                ← I2C_BASE_ADDR = 0x20000000
│   ├── lib/
│   │   ├── inc/i2c.h           ← Register offsets, bit masks, API
│   │   └── src/i2c.c           ← i2c_init(), i2c_disable()
│   └── test/
│       └── test_i2c.c          ←  gửi "GROUP12" và READ DATA qua I2C
└── openroad/
    ├── scripts/
    │   ├── 01_floorplan.tcl    ← Định nghĩa placement regions (I2C_USER_REGION)
    │   ├── reports_area.tcl    ← Hierarchical area report + I2C pin summary
    └── src/
        └── constraints.sdc     ← Timing constraints cho i2c_sda_io, i2c_scl_io
```

---

## 8. Ví dụ sử dụng phần mềm (Continuous Write & Read)

Dưới đây là ví dụ code C để gửi liên tục một chuỗi ký tự ("GROUP12") và thực hiện lệnh Đọc (READ) qua giao thức I2C:

```c
#include "i2c.h"
#include "util.h"
#include "config.h"

#define I2C_SLAVE_ADDR   0x50
#define I2C_PRESCALE_VAL 39   // ~250kHz SCL at 20MHz clk

static int wait_tip(void) {
    int timeout = 200000;
    while (!(*reg32(I2C_BASE_ADDR, I2C_STATUS_OFFSET) & I2C_STATUS_TIP)) {
        if (--timeout == 0) return 0;
    }
    timeout = 200000;
    while (*reg32(I2C_BASE_ADDR, I2C_STATUS_OFFSET) & I2C_STATUS_TIP) {
        if (--timeout == 0) return -1;
    }
    return 0;
}

// Send multiple bytes as a continuous I2C transaction
static int send_buffer(const uint8_t *data, int len) {
    *reg32(I2C_BASE_ADDR, I2C_TX_DATA_OFFSET) = (I2C_SLAVE_ADDR << 1) | I2C_WRITE_BIT;
    *reg32(I2C_BASE_ADDR, I2C_CMD_OFFSET)     = I2C_CMD_START | I2C_CMD_WRITE;
    wait_tip();

    for (int i = 0; i < len; i++) {
        *reg32(I2C_BASE_ADDR, I2C_TX_DATA_OFFSET) = data[i];
        if (i == len - 1) {
            *reg32(I2C_BASE_ADDR, I2C_CMD_OFFSET) = I2C_CMD_WRITE | I2C_CMD_STOP | I2C_CMD_IACK;
        } else {
            *reg32(I2C_BASE_ADDR, I2C_CMD_OFFSET) = I2C_CMD_WRITE | I2C_CMD_IACK;
        }
        wait_tip();
    }
    return 0;
}

// Read 1 byte from slave (READ transaction)
static int read_byte(uint8_t *rx_data) {
    *reg32(I2C_BASE_ADDR, I2C_TX_DATA_OFFSET) = (I2C_SLAVE_ADDR << 1) | I2C_READ_BIT;
    *reg32(I2C_BASE_ADDR, I2C_CMD_OFFSET)     = I2C_CMD_START | I2C_CMD_WRITE;
    wait_tip();

    if (*reg32(I2C_BASE_ADDR, I2C_STATUS_OFFSET) & I2C_STATUS_RXACK)
        return -1; // NACK

    *reg32(I2C_BASE_ADDR, I2C_CMD_OFFSET) = I2C_CMD_READ | I2C_CMD_ACK | I2C_CMD_STOP | I2C_CMD_IACK;
    wait_tip();

    *rx_data = (uint8_t)(*reg32(I2C_BASE_ADDR, I2C_RX_DATA_OFFSET) & 0xFF);
    return 0;
}

void i2c_test() {
    i2c_init(I2C_PRESCALE_VAL);
    const uint8_t group[] = {'G', 'R', 'O', 'U', 'P', '1', '2'};
    send_buffer(group, 7);

    for (int i = 0; i < 5; i++) {
        uint8_t rx = 0;
        read_byte(&rx); // Test đọc từ slave
        // In ra màn hình bằng UART:
        // printf("READ["); printf("%x", i); printf("] from slave: '"); putchar(rx); printf("'\n");
    }
}
```

---



---

*Tài liệu này được tạo cho dự án croc_i2c — tích hợp I2C Master Controller*
*vào Croc SoC trên công nghệ IHP SG13G2 130nm.*
