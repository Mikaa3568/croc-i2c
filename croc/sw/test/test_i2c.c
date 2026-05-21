

#include "uart.h"
#include "print.h"
#include "i2c.h"
#include "clint.h"
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
    // --- Burst 1: address byte ---
    *reg32(I2C_BASE_ADDR, I2C_TX_DATA_OFFSET) = (I2C_SLAVE_ADDR << 1) | I2C_WRITE_BIT;
    *reg32(I2C_BASE_ADDR, I2C_CMD_OFFSET)     = I2C_CMD_START | I2C_CMD_WRITE;
    wait_tip();

    // --- Burst 2: data bytes ---
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
    // Send address byte with READ bit
    *reg32(I2C_BASE_ADDR, I2C_TX_DATA_OFFSET) = (I2C_SLAVE_ADDR << 1) | I2C_READ_BIT;
    *reg32(I2C_BASE_ADDR, I2C_CMD_OFFSET)     = I2C_CMD_START | I2C_CMD_WRITE;
    wait_tip();

    // Check slave ACK
    if (*reg32(I2C_BASE_ADDR, I2C_STATUS_OFFSET) & I2C_STATUS_RXACK)
        return -1; // NACK

    // Read 1 byte, send NACK + STOP (last byte)
    *reg32(I2C_BASE_ADDR, I2C_CMD_OFFSET) = I2C_CMD_READ | I2C_CMD_ACK | I2C_CMD_STOP | I2C_CMD_IACK;
    wait_tip();

    *rx_data = (uint8_t)(*reg32(I2C_BASE_ADDR, I2C_RX_DATA_OFFSET) & 0xFF);
    return 0;
}

int main(void) {
    uart_init();
    printf("I2C HELLO slow\n");

    i2c_init(I2C_PRESCALE_VAL);

    static const uint8_t hello[] = {'G', 'R', 'O', 'U', 'P', '1', '2'};

    int ret = send_buffer(hello, 7);
    if (ret == 0)
        printf("HELLO sent continuously: OK\n");
    else
        printf("HELLO sent continuously: NACK\n");

    // Test READ: đọc 5 lần để nhận chữ "hello" từ slave
    for (int i = 0; i < 5; i++) {
        uint8_t rx = 0;
        ret = read_byte(&rx);
        if (ret == 0) {
            printf("READ[");
            printf("%x", i);
            printf("] from slave: '");
            putchar(rx);
            printf("' (0x%x)\n", rx);
        } else {
            printf("READ[");
            printf("%x", i);
            printf("] failed: NACK\n");
        }
    }

    i2c_disable();
    printf("DONE\n");
    uart_write_flush();
    return 0;
}
