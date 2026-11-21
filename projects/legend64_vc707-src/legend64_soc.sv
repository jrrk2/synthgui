// SPDX-License-Identifier: Apache-2.0
// legend64_soc: the legend64 core with its boot memory, DDR cache and peripherals. Everything
// here runs on the system clock except the far side of the Ethernet packet FIFOs.
//
// The layout follows QEMU's `virt` machine where the two overlap, so the same firmware and
// kernel configuration serve both:
//   0x0001_0000  64 KiB boot memory (block RAM, holds the monitor; reset entry)
//   0x0200_0000  CLINT: msip +0x0, mtimecmp +0x4000, mtime +0xbff8 (counts clock cycles)
//   0x0c00_0000  PLIC (source 10: UART, source 2: Ethernet)
//   0x1000_0000  16550-compatible UART, byte registers
//   0x2000_0000  board: LEDs +0, switches/buttons +4, status +8, clock Hz +0xc, build id +0x10,
//                reconfigure +0x18 (writing 0x4950_5247 reloads the FPGA from its flash)
//   0x3000_0000  Ethernet MAC registers (see legend_eth.sv)
//   0x4000_0000  memory controller registers, 64 KiB (LiteDRAM builds: the monitor runs the
//                DDR3 initialisation and levelling through these before it uses the memory)
//   0x6000_0000  the configuration flash (see legend_flash.sv): the 32 MiB image the board's
//                switch selects, repeated four times to fill the device's 128 MiB, because
//                the kernel's driver touches every part of the device it has identified
//   0x8000_0000  1 GiB DDR3 through the cache
module legend64_soc #(
    parameter int unsigned CLK_HZ   = 50_000_000,
    parameter int unsigned BAUD     = 115_200,
    parameter logic [31:0] BUILD_ID = 32'h0,
    parameter              BOOT_HEX = "boot.hex",
    parameter int          CACHE_LINES_LOG2 = 10,   // cache size: 64-byte lines, so 10 is 64 KiB
    parameter int          TLB_ENTRIES      = 8
) (
    input  logic         clk,
    input  logic         rst,          // synchronous
    input  logic         ddr_ready,    // the core is held in reset until this is set (synchronised by the caller)
    input  logic         ddr_soft,     // static: the memory needs software initialisation

    output logic         mem_req,
    output logic         mem_we,
    output logic [23:0]  mem_addr,
    output logic [511:0] mem_wdata,
    input  logic         mem_ack,
    input  logic [511:0] mem_rdata,

    // memory controller registers: a held-steady request/acknowledge handshake into the
    // controller's clock domain, like the line port above
    output logic         dcsr_req,
    output logic         dcsr_we,
    output logic [13:0]  dcsr_addr,    // word index
    output logic [31:0]  dcsr_wdata,
    input  logic         dcsr_ack,     // asynchronous
    input  logic [31:0]  dcsr_rdata,

    output logic         uart_tx,
    input  logic         uart_rx,
    output logic [7:0]   led,
    input  logic [7:0]   dip,
    input  logic [4:0]   btn,

    // Ethernet MAC byte streams, on the MAC's clock
    input  logic         mac_clk,      // the MAC's receive side
    input  logic         mac_rst,
    input  logic         mac_tx_clk,   // and its transmit side
    input  logic         mac_tx_rst,
    input  logic [15:0]  tx_pcs_frames,
    input  logic [7:0]   rx_tdata,
    input  logic         rx_tvalid,
    input  logic         rx_tlast,
    input  logic         rx_tuser,
    output logic [7:0]   tx_tdata,
    output logic         tx_tvalid,
    output logic         tx_tlast,
    input  logic         tx_tready,
    input  logic [15:0]  pcs_status,

    // parallel NOR flash, asynchronous bus
    output logic [23:0]  fl_addr,
    input  logic [15:0]  fl_dq_i,
    output logic [15:0]  fl_dq_o,
    output logic         fl_dq_t,
    output logic         fl_ce_n,
    output logic         fl_oe_n,
    output logic         fl_we_n,
    output logic         fl_adv_n,
    output logic         reconfig      // set, and left set, to reload the FPGA from its flash
);
  logic        imem_req, imem_gnt, imem_rvalid, dmem_req, dmem_we, dmem_gnt, dmem_rvalid;
  logic [63:0] imem_addr, dmem_addr, dmem_wdata, dmem_rdata;
  logic [31:0] imem_rdata;
  logic [7:0]  dmem_be;
  logic        core_rst_n, irq_timer, msip, irq_m_ext, irq_s_ext, uart_irq, eth_irq;
  logic [63:0] mtime, mtimecmp;

  always_ff @(posedge clk) begin
    if (rst) core_rst_n <= 1'b0;
    else     core_rst_n <= ddr_ready;
  end

  legend64 #(.RESET_PC(64'h0000_0000_0001_0000), .TLB_ENTRIES(TLB_ENTRIES)) u_core (
      .clk, .rst_n(core_rst_n),
      .imem_req, .imem_addr, .imem_gnt, .imem_rvalid, .imem_rdata,
      .dmem_req, .dmem_we, .dmem_addr, .dmem_wdata, .dmem_be, .dmem_gnt, .dmem_rvalid, .dmem_rdata,
      .irq_m_ext, .irq_m_timer(irq_timer), .irq_m_soft(msip), .irq_s_ext, .time_i(mtime),
      .tr_valid(), .tr_pc(), .tr_insn(), .tr_wen(), .tr_fwen(), .tr_rd(), .tr_wdata(),
      .tr_trap(), .tr_trap_late(), .tr_cause(), .tr_epc(), .tr_tval()
  );

  // ------------------------------------------------------------------ address decode
  logic i_boot, i_ddr, d_boot, d_ddr, d_mmio;
  assign i_boot = imem_addr[63:16] == 48'h1;
  assign i_ddr  = imem_addr[63:30] == 34'h2;
  assign d_boot = dmem_addr[63:16] == 48'h1;
  assign d_ddr  = dmem_addr[63:30] == 34'h2;
  assign d_mmio = !d_boot && !d_ddr;

  // ------------------------------------------------------------------ boot memory
  // The instruction port takes its address from a register: the fetch address comes late out of
  // the execute stage (a redirect) and the memory's block RAMs are spread out, and nothing that
  // matters for speed runs from here. A fetch from the boot memory is accepted at once and
  // occupies the next cycle (bi_v), during which the instruction bus accepts nothing, so its
  // answer cannot meet a later fetch's: the instruction two cycles after the request.
  logic [63:0] boot_iq, boot_dq;
  logic        boot_i_rv, boot_i_hi, boot_d_rv, none_i_rv;
  logic        bi_v, bi_hi, i_req;
  logic [12:0] bi_addr;
  assign i_req = imem_req && !bi_v;
  always_ff @(posedge clk) begin
    bi_v    <= i_req && i_boot && core_rst_n;
    bi_hi   <= imem_addr[2];
    bi_addr <= imem_addr[15:3];
  end
  legend_tdp_be #(.AW(13), .NB(8), .INIT_FILE(BOOT_HEX)) u_boot (
      .clk,
      .a_addr(bi_addr), .a_q(boot_iq),
      .b_addr(dmem_addr[15:3]), .b_we((dmem_req && dmem_we && d_boot) ? dmem_be : 8'h00),
      .b_d(dmem_wdata), .b_q(boot_dq)
  );

  // ------------------------------------------------------------------ DDR cache
  logic        c_i_gnt, c_i_rvalid, c_d_gnt, c_d_rvalid;
  logic [31:0] c_i_rdata;
  logic [63:0] c_d_rdata;
  logic        e_req, e_we, e_gnt, e_rvalid;
  logic [29:0] e_addr;
  logic [63:0] e_wdata, e_rdata;
  logic [7:0]  e_be;
  legend_cache #(.LINES_LOG2(CACHE_LINES_LOG2)) u_cache (
      .clk, .rst(!core_rst_n),
      .i_req(i_req && i_ddr), .i_addr(imem_addr[29:0]), .i_gnt(c_i_gnt), .i_rvalid(c_i_rvalid), .i_rdata(c_i_rdata),
      .d_req(dmem_req && d_ddr), .d_we(dmem_we), .d_addr(dmem_addr[29:0]), .d_wdata(dmem_wdata), .d_be(dmem_be),
      .d_gnt(c_d_gnt), .d_rvalid(c_d_rvalid), .d_rdata(c_d_rdata),
      .e_req, .e_we, .e_addr, .e_wdata, .e_be, .e_gnt, .e_rvalid, .e_rdata,
      .mem_req, .mem_we, .mem_addr, .mem_wdata, .mem_ack, .mem_rdata
  );

  // ------------------------------------------------------------------ peripherals
  logic        mmio_wr, mmio_rd, mmio_acc, sel_uart, sel_plic, sel_eth, sel_dcsr, sel_flash, dcsr_gnt, fl_gnt;
  logic [31:0] wr32, plic_q, eth_q;
  logic [7:0]  uart_q;
  logic [63:0] mmio_q;
  logic        mmio_rv;
  logic [2:0]  mmio_src;      // 0: mmio_q, 1: PLIC, 2: Ethernet, 3: memory controller, 4: flash
  logic [63:0] fl_q;

  assign mmio_acc = dmem_req && dmem_gnt && d_mmio;
  assign mmio_wr  = mmio_acc && dmem_we;
  assign mmio_rd  = mmio_acc && !dmem_we;
  assign wr32     = dmem_addr[2] ? dmem_wdata[63:32] : dmem_wdata[31:0];
  assign sel_uart = dmem_addr[31:3]  == 29'h1000_0000 >> 3;
  assign sel_plic = dmem_addr[31:26] == 6'h03;                 // 0x0c00_0000 .. 0x0fff_ffff
  assign sel_eth  = dmem_addr[31:12] == 20'h30000;
  assign sel_dcsr = dmem_addr[31:16] == 16'h4000;
  assign sel_flash = dmem_addr[31:27] == 5'h0c;                // 0x6000_0000 .. 0x67ff_ffff

  // An access to the memory controller's registers is granted only when its handshake has
  // completed; the core holds the request steady until then.
  (* ASYNC_REG = "TRUE" *) logic [1:0] dcsr_ack_s;
  logic [31:0] dcsr_q;
  assign dcsr_addr  = dmem_addr[15:2];
  assign dcsr_we    = dmem_we;
  assign dcsr_wdata = wr32;
  assign dcsr_gnt   = dcsr_req && dcsr_ack_s[1];
  always_ff @(posedge clk) begin
    dcsr_ack_s <= {dcsr_ack_s[0], dcsr_ack};
    if (!core_rst_n) begin dcsr_req <= 1'b0; dcsr_ack_s <= '0; dcsr_q <= '0; end
    else if (dcsr_gnt) begin dcsr_req <= 1'b0; dcsr_q <= dcsr_rdata; end
    else if (dmem_req && d_mmio && sel_dcsr && !dcsr_ack_s[1]) dcsr_req <= 1'b1;
  end

  legend_flash #(.CLK_HZ(CLK_HZ)) u_flash (
      .clk, .rst(!core_rst_n),
      .req(dmem_req && d_mmio && sel_flash && !fl_gnt), .we(dmem_we), .addr(dmem_addr[24:1]),
      .be(dmem_be), .wdata(dmem_wdata), .gnt(fl_gnt), .rdata(fl_q),
      .fl_addr, .fl_dq_i, .fl_dq_o, .fl_dq_t, .fl_ce_n, .fl_oe_n, .fl_we_n, .fl_adv_n
  );

  legend_uart16550 #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_uart (
      .clk, .rst(!core_rst_n),
      .sel(mmio_acc && sel_uart), .we(dmem_we), .addr(dmem_addr[2:0]),
      .wdata(dmem_wdata[{dmem_addr[2:0], 3'b000}+:8]), .rdata(uart_q), .irq(uart_irq),
      .rx(uart_rx), .tx(uart_tx)
  );

  logic [31:1] plic_src;
  always_comb begin
    plic_src = '0;
    plic_src[10] = uart_irq;
    plic_src[2]  = eth_irq;
  end
  legend_plic u_plic (
      .clk, .rst(!core_rst_n),
      .sel(mmio_acc && sel_plic), .we(dmem_we), .addr(dmem_addr[25:0]), .wdata(wr32), .rdata(plic_q),
      .src(plic_src), .irq_m(irq_m_ext), .irq_s(irq_s_ext)
  );

  legend_eth u_eth (
      .clk, .rst(!core_rst_n),
      .reg_sel(mmio_acc && sel_eth), .reg_we(dmem_we), .reg_addr(dmem_addr[7:0]), .reg_wdata(wr32),
      .reg_rdata(eth_q), .irq(eth_irq),
      .e_req, .e_we, .e_addr, .e_wdata, .e_be, .e_gnt, .e_rvalid, .e_rdata,
      .mac_clk, .mac_rst, .mac_tx_clk, .mac_tx_rst, .rx_tdata, .rx_tvalid, .rx_tlast, .rx_tuser,
      .tx_tdata, .tx_tvalid, .tx_tlast, .tx_tready, .tx_pcs_frames, .pcs_status
  );

  assign irq_timer = mtime >= mtimecmp;

  always_ff @(posedge clk) begin
    mmio_rv  <= mmio_rd;
    mmio_src <= sel_plic ? 3'd1 : sel_eth ? 3'd2 : sel_dcsr ? 3'd3 : sel_flash ? 3'd4 : 3'd0;
    mtime    <= mtime + 64'd1;
    if (!core_rst_n) begin
      led <= '0; msip <= 1'b0; mtime <= '0; mtimecmp <= '1; mmio_rv <= 1'b0;
      mmio_src <= '0; mmio_q <= '0; reconfig <= 1'b0;
    end else begin
      if (mmio_wr) begin
        case (dmem_addr[31:0])
          32'h0200_0000: msip <= wr32[0];
          32'h0200_4000: mtimecmp <= dmem_wdata;
          32'h0200_bff8: mtime <= dmem_wdata;
          32'h2000_0000: led <= wr32[7:0];
          32'h2000_0018: if (wr32 == 32'h4950_5247) reconfig <= 1'b1;
          default: ;
        endcase
      end
      if (mmio_rd) begin
        case ({dmem_addr[31:3], 3'b000})
          32'h0200_0000: mmio_q <= {63'b0, msip};
          32'h0200_4000: mmio_q <= mtimecmp;
          32'h0200_bff8: mmio_q <= mtime;
          32'h1000_0000: mmio_q <= {8{uart_q}};
          32'h2000_0000: mmio_q <= {19'b0, btn, dip, 24'b0, led};
          32'h2000_0008: mmio_q <= {CLK_HZ, 14'b0, ddr_soft, ddr_ready, pcs_status};
          32'h2000_0010: mmio_q <= {32'b0, BUILD_ID};
          default:       mmio_q <= '0;
        endcase
      end
    end
  end

  // ------------------------------------------------------------------ bus responses
  assign imem_gnt = bi_v ? 1'b0 : i_ddr ? c_i_gnt : 1'b1;
  always_ff @(posedge clk) begin
    boot_i_rv <= bi_v;
    none_i_rv <= i_req && imem_gnt && !i_boot && !i_ddr;
    boot_i_hi <= bi_hi;
    boot_d_rv <= dmem_req && dmem_gnt && !dmem_we && d_boot;
    if (!core_rst_n) begin boot_i_rv <= 1'b0; none_i_rv <= 1'b0; boot_d_rv <= 1'b0; boot_i_hi <= 1'b0; end
  end
  assign imem_rvalid = boot_i_rv || none_i_rv || c_i_rvalid;
  assign imem_rdata  = boot_i_rv ? (boot_i_hi ? boot_iq[63:32] : boot_iq[31:0]) : none_i_rv ? 32'h0 : c_i_rdata;

  assign dmem_gnt    = d_ddr ? c_d_gnt : (d_mmio && sel_dcsr) ? dcsr_gnt : (d_mmio && sel_flash) ? fl_gnt : 1'b1;
  assign dmem_rvalid = boot_d_rv || mmio_rv || c_d_rvalid;
  assign dmem_rdata  = boot_d_rv ? boot_dq
                     : mmio_rv ? (mmio_src == 3'd1 ? {2{plic_q}} : mmio_src == 3'd2 ? {2{eth_q}} : mmio_src == 3'd3 ? {2{dcsr_q}}
                                : mmio_src == 3'd4 ? fl_q : mmio_q)
                     : c_d_rdata;
endmodule
