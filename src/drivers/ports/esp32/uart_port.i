/**
 * @file drivers/esp/uart_port.i
 *
 * @section License
 * Copyright (C) 2014-2016, Erik Moqvist
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * This file is part of the Simba project.
 */

#undef BIT

#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "esp_intr.h"

extern xSemaphoreHandle thrd_idle_sem;

static struct fs_counter_t rx_channel_overflow;
static struct fs_counter_t rx_errors;

/**
 * Fill the tx fifo with data from given uart driver.
 */
static void fill_tx_fifo(struct uart_driver_t *drv_p)
{
    while ((drv_p->txsize > 0)
           && ((drv_p->dev_p->regs_p->STATUS
                & ESP32_UART_STATUS_TXFIFO_CNT_MASK)
               < ESP32_UART_STATUS_TXFIFO_CNT(128))) {
        drv_p->dev_p->regs_p->FIFO = *drv_p->txbuf_p++;
        drv_p->txsize--;
    }
}

static inline void tx_isr(struct uart_driver_t *drv_p,
                          struct uart_device_t *dev_p)
{
    /* Clear the interrupt. */
    dev_p->regs_p->INT_CLR = ESP32_UART_INT_CLR_TXFIFO_EMPTY;

    /* Fill the fifo (if there is more data to send). */
    fill_tx_fifo(drv_p);

    /* Resume the writing thread when all data has been written to the
       fifo. */
    if (drv_p->txsize == 0) {
        dev_p->regs_p->INT_ENA &= ~ESP32_UART_INT_ENA_TXFIFO_EMPTY;
        thrd_resume_isr(drv_p->thrd_p, 0);

        xSemaphoreGiveFromISR(thrd_idle_sem, NULL);
    }
}

static inline void rx_isr(struct uart_driver_t *drv_p,
                          struct uart_device_t *dev_p)
{
    char c;
    uint32_t error;

    /* ToDo: hande errors.*/
    error = 0;
    c = dev_p->regs_p->FIFO;

    /* Clear the interrupt. */
    dev_p->regs_p->INT_CLR = ESP32_UART_INT_CLR_RXFIFO_FULL;

    /* Error frames are discarded. */
    if (error == 0) {
        /* Write data to the input channel. */
        if (chan_write_isr(&drv_p->chin, &c, 1) != 1) {
            fs_counter_increment(&rx_channel_overflow, 1);
        }

        xSemaphoreGiveFromISR(thrd_idle_sem, NULL);
    } else {
        fs_counter_increment(&rx_errors, 1);
    }
}

static void isr(void *arg_p)
{
    int cpu_interrupt;
    struct uart_device_t *dev_p;
    struct uart_driver_t *drv_p;
    int i;

    cpu_interrupt = *(int *)arg_p;

    for (i = 0; i < membersof(uart_device); i++) {
        dev_p = &uart_device[i];

        /* Only handle the devices assigned to this CPU interrupt. */
        if (dev_p->interrupt.cpu != cpu_interrupt) {
            continue;
        }

        drv_p = dev_p->drv_p;

        if (dev_p->regs_p->INT_ST & ESP32_UART_INT_ST_TXFIFO_EMPTY) {
            tx_isr(drv_p, dev_p);
        }

        if (dev_p->regs_p->INT_ST & ESP32_UART_INT_ST_RXFIFO_FULL) {
            rx_isr(drv_p, dev_p);
        }
    }
}

static int uart_port_module_init()
{
    int i;

    fs_counter_init(&rx_channel_overflow,
                    FSTR("/drivers/uart/rx_channel_overflow"),
                    0);
    fs_counter_register(&rx_channel_overflow);

    fs_counter_init(&rx_errors,
                    FSTR("/drivers/uart/rx_errors"),
                    0);
    fs_counter_register(&rx_errors);

    /* The CPU interrupts. A CPU interrupt may be shared among
       multiple UART devices. */
    for (i = 0; i < UART_DEVICE_MAX; i++) {
        xt_set_interrupt_handler(uart_device[i].interrupt.cpu,
                                 isr,
                                 &uart_device[i].interrupt.cpu);
        xt_ints_on(BIT(uart_device[i].interrupt.cpu));
    }

    return (0);
}

static int uart_port_start(struct uart_driver_t *drv_p)
{
    volatile struct esp32_uart_t *regs_p;

    regs_p = drv_p->dev_p->regs_p;

    /* Wait until the transmit fifo is empty. */
    while ((regs_p->STATUS & ESP32_UART_STATUS_TXFIFO_CNT_MASK) != 0);

    /* Configure the hardware and reset the fifos. */
    regs_p->CLKDIV = (80000000 / drv_p->baudrate);
    regs_p->CONF0 |= (ESP32_UART_CONF0_TXFIFO_RST
                      | ESP32_UART_CONF0_RXFIFO_RST);
    regs_p->CONF0 &= (~(ESP32_UART_CONF0_TXFIFO_RST
                        | ESP32_UART_CONF0_RXFIFO_RST));

    regs_p->INT_ENA = (ESP32_UART_INT_ST_RXFIFO_FULL);

    drv_p->dev_p->drv_p = drv_p;

    /* Map given peripheral interrupts to given CPU interrupt. */
    intr_matrix_set(xPortGetCoreID(),
                    drv_p->dev_p->interrupt.source,
                    drv_p->dev_p->interrupt.cpu);

    return (0);
}

static int uart_port_stop(struct uart_driver_t *drv_p)
{
    intr_matrix_set(xPortGetCoreID(),
                    drv_p->dev_p->interrupt.source,
                    PERIPHERAL_DISABLED);

    return (0);
}

static ssize_t uart_port_write_cb(void *arg_p,
                                  const void *txbuf_p,
                                  size_t size)
{
    struct uart_driver_t *self_p;

    self_p = container_of(arg_p, struct uart_driver_t, chout);

    sem_take(&self_p->sem, NULL);

    /* Initiate transfer by writing to the fifo. */
    self_p->txbuf_p = txbuf_p;
    self_p->txsize = size;
    self_p->thrd_p = thrd_self();

    sys_lock();

    /* fill_tx_fifo(self_p); */
    /* self_p->dev_p->regs_p->INT_ENA |= ESP32_UART_INT_ENA_TXFIFO_EMPTY; */

    while (self_p->txsize > 0) {
        fill_tx_fifo(self_p);
    }

    /* thrd_suspend_isr(NULL); */

    sys_unlock();

    sem_give(&self_p->sem, 1);

    return (size);
}

static ssize_t uart_port_write_cb_isr(void *arg_p,
                                      const void *txbuf_p,
                                      size_t size)
{
    struct uart_driver_t *self_p;

    self_p = container_of(arg_p, struct uart_driver_t, chout);

    /* Initiate transfer by writing to the fifo. */
    self_p->txbuf_p = txbuf_p;
    self_p->txsize = size;

    while (self_p->txsize > 0) {
        fill_tx_fifo(self_p);
    }

    return (size);
}