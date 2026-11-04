// csr accessors over a /dev/mem mapping of the CSR space
#pragma once
#include <stdint.h>
extern volatile uint8_t *csr_map;
#define CSR_LINUX_BASE 0xf0000000UL
#define CONFIG_CSR_DATA_WIDTH 32
static inline void csr_write_simple(unsigned long v, unsigned long a) { *(volatile uint32_t *)(csr_map + (a - CSR_LINUX_BASE)) = v; }
static inline unsigned long csr_read_simple(unsigned long a) { return *(volatile uint32_t *)(csr_map + (a - CSR_LINUX_BASE)); }
