`define TRACE_WAVE

module tb_croc_soc #(
  parameter int unsigned GpioCount = 32
);

  import tb_croc_pkg::*;

  // Signals fully controlled by the VIP
  // use VIP functions/tasks to manipulate these signals
  logic rst_n;
  logic sys_clk;
  logic ref_clk;

  logic jtag_tck;
  logic jtag_trst_n;
  logic jtag_tms;
  logic jtag_tdi;
  logic jtag_tdo;

  logic uart_rx;
  logic uart_tx;

  // Signals partially controlled by the VIP
  logic [GpioCount-1:0] gpio_in;
  logic [GpioCount-1:0] gpio_out;
  logic [GpioCount-1:0] gpio_out_en;

  logic i2c_sda_i;
  logic i2c_sda_o;
  logic i2c_sda_oe;
  logic i2c_scl_i;
  logic i2c_scl_o;
  logic i2c_scl_oe;

  // Signals controlled by the testbench

  /////////////////////////////
  //  Command Line Arguments //
  /////////////////////////////

  string binary_path;

  initial begin
    // $value$plusargs defines what to look for (here +binary=...)
    if ($value$plusargs("binary=%s", binary_path)) begin
      $display("Running program: %s", binary_path);
    end else begin
      $display("No binary path provided. Running helloworld.");
      binary_path = "../sw/bin/helloworld.hex";
    end
  end

  ////////////
  //  VIP   //
  ////////////
  croc_vip #(
    .GpioCount ( GpioCount )
  ) i_vip (
    .rst_no        ( rst_n        ),
    .sys_clk_o     ( sys_clk     ),
    .ref_clk_o     ( ref_clk     ),
    .jtag_tck_o    ( jtag_tck    ),
    .jtag_trst_no  ( jtag_trst_n ),
    .jtag_tms_o    ( jtag_tms    ),
    .jtag_tdi_o    ( jtag_tdi    ),
    .jtag_tdo_i    ( jtag_tdo    ),
    .uart_rx_o     ( uart_rx     ),
    .uart_tx_i     ( uart_tx     ),
    .gpio_out_en_i ( gpio_out_en ),
    .gpio_out_i    ( gpio_out    ),
    .gpio_in_o     ( gpio_in     )
  );

  ////////////
  //  DUT   //
  ////////////

  `ifdef TARGET_NETLIST_YOSYS
  \croc_soc$croc_chip.i_croc_soc i_croc_soc (
  `else
  croc_soc #(
    .GpioCount ( GpioCount )
  ) i_croc_soc (
  `endif
    .clk_i         ( sys_clk     ),
    .rst_ni        ( rst_n       ),
    .ref_clk_i     ( ref_clk     ),
    .testmode_i    ( 1'b0        ),
    .status_o      (             ),
    .jtag_tck_i    ( jtag_tck    ),
    .jtag_tdi_i    ( jtag_tdi    ),
    .jtag_tdo_o    ( jtag_tdo    ),
    .jtag_tms_i    ( jtag_tms    ),
    .jtag_trst_ni  ( jtag_trst_n ),
    .uart_rx_i     ( uart_rx     ),
    .uart_tx_o     ( uart_tx     ),
    .gpio_i        ( gpio_in     ),
    .gpio_o        ( gpio_out    ),
    .gpio_out_en_o ( gpio_out_en ),
    .i2c_sda_i     ( i2c_sda_i   ),
    .i2c_sda_o     ( i2c_sda_o   ),
    .i2c_sda_oe    ( i2c_sda_oe  ),
    .i2c_scl_i     ( i2c_scl_i   ),
    .i2c_scl_o     ( i2c_scl_o   ),
    .i2c_scl_oe    ( i2c_scl_oe  )
  );

  /////////////////
  //  Testbench  //
  /////////////////

  // I2C Bus Pullups and Dummy Slave Model
  wire scl = i2c_scl_oe ? i2c_scl_o : 1'b1;
  wire sda_master = i2c_sda_oe ? i2c_sda_o : 1'b1;
  
  logic sda_slave_oe = 0;
  wire sda = sda_master & (sda_slave_oe ? 1'b0 : 1'b1);
  
  assign i2c_scl_i = scl;
  assign i2c_sda_i = sda;

  int i2c_bit_cnt = 0;
  logic i2c_started = 0;
  logic is_address_byte = 0;
  logic [7:0] i2c_rx_data;
  logic [7:0] hello_str [0:4] = '{ "h", "e", "l", "l", "o" };
  int hello_idx = 0;
  logic [7:0] i2c_tx_data; 
  logic is_read_mode = 0;
  logic [7:0] i2c_tx_shift;         
  wire  i2c_tx_bit = i2c_tx_shift[7]; 

  logic scl_d1 = 1, scl_d2 = 1;
  logic sda_d1 = 1, sda_d2 = 1;
  
  always @(posedge sys_clk) begin
    if (rst_n == 1'b0) begin
      scl_d1        <= 1'b1; 
      scl_d2        <= 1'b1;
      sda_d1        <= 1'b1; 
      sda_d2        <= 1'b1;
      i2c_started   <= 1'b0;
      sda_slave_oe  <= 1'b0;
      i2c_bit_cnt   <= 0;
      hello_idx     <= 0;
      is_read_mode  <= 1'b0;
      is_address_byte <= 1'b0;
      i2c_tx_data   <= hello_str[0]; 
    end else begin
      scl_d1 <= scl;
      scl_d2 <= scl_d1;
      sda_d1 <= sda;
      sda_d2 <= sda_d1;
      
      // START condition
      if (scl_d2 == 1'b1 && scl_d1 == 1'b1 && sda_d2 == 1'b1 && sda_d1 == 1'b0) begin
        i2c_started     <= 1'b1;
        i2c_bit_cnt     <= 0;
        sda_slave_oe    <= 1'b0;
        is_address_byte <= 1'b1;
      end
      // STOP condition
      else if (scl_d2 == 1'b1 && scl_d1 == 1'b1 && sda_d2 == 1'b0 && sda_d1 == 1'b1) begin
        i2c_started     <= 1'b0;
        sda_slave_oe    <= 1'b0;
        is_read_mode    <= 1'b0;
      end
      else if (i2c_started) begin
        
        // ============================================================
        // SCL Falling Edge: Điều khiển trạng thái chân SDA (Thay đổi dữ liệu)
        // ============================================================
        if (scl_d2 == 1'b1 && scl_d1 == 1'b0) begin
          if (i2c_bit_cnt == 9) begin
            i2c_bit_cnt <= 1;
            if (is_read_mode) begin
              i2c_tx_shift <= i2c_tx_data; 
              sda_slave_oe <= ~i2c_tx_data[7];
            end else begin
              sda_slave_oe <= 1'b0;
            end
          end else begin
            i2c_bit_cnt <= i2c_bit_cnt + 1;
            
            if (i2c_bit_cnt == 8) begin // Phase ACK/NACK (Xung nhịp thứ 9)
              if (is_address_byte) begin
                // --- 1. SLAVE PHẢN HỒI ACK CHO ĐỊA CHỈ ---
                sda_slave_oe    = 1'b1; 
                is_address_byte <= 1'b0;
                
                #0; // Đợi mạch vật lý gán xong
                if (sda == 1'b0) begin
                  $display("@%0t | [I2C Slave] Nhận Address: 0x%02x (R/W: %s) -> Slave phản hồi [ACK] ✓",
                           $time, i2c_rx_data, i2c_rx_data[0] ? "READ" : "WRITE");
                end else begin
                  $error("@%0t | [I2C Slave] LỖI VẬT LÝ: Nhận Address: 0x%02x nhưng Bus lỗi [NACK] ✗",
                           $time, i2c_rx_data);
                end
                
                if (i2c_rx_data[0]) begin
                  is_read_mode <= 1'b1;
                end
              end 
              else if (is_read_mode) begin
                // --- 2. MASTER PHẢN HỒI ACK/NACK KHI ĐỌC DỮ LIỆU TỪ SLAVE ---
                sda_slave_oe <= 1'b0; // Nhả SDA để Master ép xung điều khiển
                
                #0; // Đợi Master dập hoặc nhả bus
                if (i2c_tx_shift == i2c_tx_data) begin
                  if (sda_master == 1'b0)
                    $display("@%0t | [I2C Slave] TX OK: sent '%c' (0x%02x)", $time, i2c_tx_data, i2c_tx_data);
                  else
                    $display("@%0t | [I2C Slave] TX STOP: sent '%c' (0x%02x) -> Master thả nổi [NACK] ✗ (Kết thúc đọc)", $time, i2c_tx_data, i2c_tx_data);
                end else begin
                  $error ("@%0t | [I2C Slave] TX FAIL: sent 0x%02x, but got 0x%02x ✗", $time, i2c_tx_data, i2c_tx_shift);
                end
                
                // Cấu hình tăng mảng dịch chữ "hello"
                if (hello_idx == 4) begin
                  hello_idx   <= 0;
                  i2c_tx_data <= hello_str[0]; 
                end else begin
                  hello_idx   <= hello_idx + 1;
                  i2c_tx_data <= hello_str[hello_idx + 1]; 
                end
                
                is_read_mode <= 1'b0; 
              end 
              else begin
                // --- 3. SLAVE PHẢN HỒI ACK KHI MASTER WRITE DATA (CÓ KIỂM TRA LỖI HAI CHIỀU) ---
                sda_slave_oe = 1'b1; // Slave kích công tắc dập dây xuống 0
                
                #0; // Đợi 1 tick thời gian cực tiểu để bus cập nhật trạng thái thực tế
                if (sda == 1'b0) begin
                  $display("@%0t | [I2C Slave] Nhận Data: 0x%02x (Ký tự: '%c') -> Slave phản hồi [ACK] ✓",
                           $time, i2c_rx_data, i2c_rx_data);
                end else begin
                  $error("@%0t | [I2C Slave] CẢNH BÁO LỖI: Nhận Data: 0x%02x nhưng đường Bus bị nghẽn [NACK] ✗",
                           $time, i2c_rx_data);
                end
              end
            end 
            else if (is_read_mode) begin
              sda_slave_oe <= ~i2c_tx_shift[7];
            end
          end
        end
        
        // ============================================================
        // SCL Rising Edge: Chốt dữ liệu ổn định từ đường truyền
        // ============================================================
        else if (scl_d2 == 1'b0 && scl_d1 == 1'b1) begin
          if (i2c_bit_cnt >= 1 && i2c_bit_cnt <= 8) begin
            if (!is_read_mode)
              i2c_rx_data  <= {i2c_rx_data[6:0], sda_master}; 
            else
              i2c_tx_shift <= {i2c_tx_shift[6:0], sda};        
          end
        end
        
      end
    end
  end

  logic [31:0] tb_data;

  initial begin
    $timeformat(-9, 0, "ns", 12); 

    // wait for reset
    #ClkPeriodSys;

    // init jtag
    i_vip.jtag_init();

    // write test value to sram
    i_vip.jtag_write_reg32(SramBaseAddr, 32'h1234_5678, 1'b1);

    // load binary to sram
    i_vip.jtag_load_hex(binary_path);

    // wake core from WFI by writing to CLINT msip
    $display("@%t | [CORE] Waking core via CLINT msip", $time);
    i_vip.jtag_write_reg32(ClintBaseAddr, 32'h1);

    // halt core
    i_vip.jtag_halt();

    // resume core
    i_vip.jtag_resume();

    // wait for non-zero return value (written into core status register)
    $display("@%t | [CORE] Wait for end of code...", $time);
    i_vip.jtag_wait_for_eoc(tb_data);

    // finish simulation
    repeat(50) @(posedge sys_clk);
    $finish();
  end

  ////////////////
  //  Waveform  //
  ////////////////
  initial begin
    `ifdef TRACE_WAVE
      `ifdef VERILATOR
        $dumpfile("croc.fst");
        $dumpvars(1, i_croc_soc);
        $dumpvars(1, tb_croc_soc); 
      `else
        $dumpfile("croc.vcd");
        $dumpvars(1, i_croc_soc);
        $dumpvars(1, tb_croc_soc);
      `endif
    `endif
  end

  final begin
    `ifdef TRACE_WAVE
      $dumpflush;
    `endif
  end

endmodule