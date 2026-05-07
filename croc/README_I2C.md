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
| Real silicon | 50 MHz | 249 (0xF9) | 100 kHz |
| Real silicon | 50 MHz | 61 (0x3D) | 400 kHz |

**Giá trị mặc định sau reset:** `prescaler = 0x00F9` → 100 kHz tại 50 MHz clock.

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

## 5. Thống kê diện tích chip (Area Report)

Kết quả từ OpenROAD sau synthesis + place & route (IHP SG13G2 130nm):

### 5.1 Tổng thể chip

| Thông số | Giá trị |
|----------|---------|
| Die Area | **3,671,056 µm²** (≈ 1.916 mm × 1.916 mm) |
| Core Area | **1,571,082 µm²** |
| Total Active Area | **691,094 µm²** |
| Core Utilization | **44.0%** |
| Std Cell Utilization | **36.5%** |

### 5.2 Khối I2C

| Instance | Area (µm²) | Std Cells | % Core |
|----------|-----------|-----------|--------|
| `i_user` (toàn bộ user_domain) | **11,623 µm²** | 726 | 0.74% |
| `i_i2c` (I2C master) | **9,275 µm²** | 520 | 0.59% |

> **Nhận xét:** Khối I2C chiếm **~80% diện tích của user_domain** và chỉ ~0.59% diện tích core.
> Đây là tỷ lệ hợp lý cho một ngoại vi I2C full-featured.

### 5.3 Sub-modules trong i_i2c (ước tính)

| Sub-module | Chức năng | Ước tính cells |
|-----------|-----------|----------------|
| `i_clkgen` | SCL prescaler 16-bit | ~30 |
| `i_ctrl` | I2C bit-level FSM | ~250 |
| `i_regif` | OBI register interface | ~180 |

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
[I2C Slave] Nhận được Address: 0xa0 (Read/Write: WRITE)
[I2C Slave] Nhận được Data: 0x48 (Ký tự: 'H')
[I2C Slave] Nhận được Data: 0x45 (Ký tự: 'E')
[I2C Slave] Nhận được Data: 0x4c (Ký tự: 'L')
[I2C Slave] Nhận được Data: 0x4c (Ký tự: 'L')
[I2C Slave] Nhận được Data: 0x4f (Ký tự: 'O')
[UART] HELLO sent continuously: OK
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
│   │   ├── i2c.sv              ← I2C master (top + 3 sub-modules)
│   │   └── i2c_reg_pkg.sv      ← Register package definitions
│   ├── user_domain.sv          ← Kết nối i_i2c vào OBI demux
│   └── croc_chip.sv            ← Kết nối pad inout với soc_i2c_* signals
├── sw/
│   ├── config.h                ← I2C_BASE_ADDR = 0x20000000
│   ├── lib/
│   │   ├── inc/i2c.h           ← Register offsets, bit masks, API
│   │   └── src/i2c.c           ← i2c_init(), i2c_disable()
│   └── test/
│       └── test_i2c.c          ←  gửi "HELLO" qua I2C
└── openroad/
    ├── scripts/
    │   ├── 01_floorplan.tcl    ← Định nghĩa placement regions (I2C_USER_REGION)
    │   ├── reports_area.tcl    ← Hierarchical area report + I2C pin summary
    └── src/
        └── constraints.sdc     ← Timing constraints cho i2c_sda_io, i2c_scl_io
```

---

## 8. Ví dụ sử dụng phần mềm (Continuous Write)

Dưới đây là ví dụ code C để gửi liên tục một chuỗi ký tự ("HELLO") qua giao thức I2C bằng phương pháp kiểm tra cờ `TIP` (Transfer In Progress):

```c
#include "i2c.h"
#include "util.h"
#include "config.h"

#define I2C_SLAVE_ADDR   0x50
#define I2C_PRESCALE_VAL 39   // ~250kHz SCL at 20MHz clk

void i2c_send_hello() {
    // 1. Khởi tạo I2C
    i2c_init(I2C_PRESCALE_VAL);

    // 2. Gửi byte địa chỉ slave (Lệnh START + WRITE)
    *reg32(I2C_BASE_ADDR, I2C_TX_DATA_OFFSET) = (I2C_SLAVE_ADDR << 1) | 0;
    *reg32(I2C_BASE_ADDR, I2C_CMD_OFFSET)     = I2C_CMD_START | I2C_CMD_WRITE;
    while (*reg32(I2C_BASE_ADDR, I2C_STATUS_OFFSET) & I2C_STATUS_TIP) {} // Chờ gửi xong

    // 3. Gửi liên tục mảng dữ liệu (Multi-byte write)
    const uint8_t data[] = {'H', 'E', 'L', 'L', 'O'};
    for (int i = 0; i < 5; i++) {
        *reg32(I2C_BASE_ADDR, I2C_TX_DATA_OFFSET) = data[i];
        
        if (i == 4) {
            // Byte cuối cùng: Gửi dữ liệu kèm lệnh STOP
            *reg32(I2C_BASE_ADDR, I2C_CMD_OFFSET) = I2C_CMD_WRITE | I2C_CMD_STOP | I2C_CMD_IACK;
        } else {
            // Các byte giữa: Chỉ gửi lệnh WRITE tiếp tục
            *reg32(I2C_BASE_ADDR, I2C_CMD_OFFSET) = I2C_CMD_WRITE | I2C_CMD_IACK;
        }
        
        while (*reg32(I2C_BASE_ADDR, I2C_STATUS_OFFSET) & I2C_STATUS_TIP) {} // Chờ gửi xong
    }
}
```

---

## 9. Lưu ý quan trọng

> **Dummy Slave trong Testbench:** Để mô phỏng hoạt động thực tế, file `tb_croc_soc.sv` đã tích hợp sẵn một Slave giả lập. Slave này tự động lắng nghe bus I2C, phản hồi ACK ở bit thứ 9 và in ra log các ký tự nhận được. Do đó, bạn sẽ nhận được ACK (thành công) và không còn gặp lỗi NACK trong log mô phỏng.

> **Open-drain model:** Module không thực sự xuất `sda_o = 1`. Thay vào đó:
> khi `sda_oe = 0`, đường SDA được điện trở pull-up ngoài kéo lên HIGH.
> Đây là yêu cầu bắt buộc của chuẩn I2C.

> **Timing constraint:** File `constraints.sdc` đặt input/output delay cho
> `i2c_sda_io` và `i2c_scl_io` tại 10%-30% chu kỳ clock hệ thống.

---

*Tài liệu này được tạo cho dự án croc_i2c — tích hợp I2C Master Controller*
*vào Croc SoC trên công nghệ IHP SG13G2 130nm.*
