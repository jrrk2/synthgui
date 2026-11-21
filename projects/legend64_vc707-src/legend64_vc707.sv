// SPDX-License-Identifier: Apache-2.0
// legend64_vc707: legend64 on the Xilinx VC707 with 1 GiB of DDR3 and SGMII Ethernet.
//
//   200 MHz board clock -> Xilinx memory interface (DDR3-1600, 200 MHz user clock)
//                          or LiteDRAM (DDR3-800, 100 MHz user clock)
//                       -> MMCM -> clk_sys (the core, 1 GHz / SYS_DIV) and clk_mac (125 MHz)
//
// The SGMII PHY/PCS and the byte-stream MAC (LiteEth's PHY, eth_mac_1g and what they use) come
// from synthgui's vc707_ethmin project, unmodified; legend_sgmii joins them.
module legend64_vc707 #(
    parameter real         SYS_DIV  = 20.0,
    parameter bit          LITEDRAM = 1'b0,    // 0: Xilinx memory interface, 1: LiteDRAM
    parameter int unsigned CLK_HZ   = 50_000_000,
    parameter logic [31:0] BUILD_ID = 32'h0,
    parameter              BOOT_HEX = "boot.hex",
    parameter int          CACHE_LINES_LOG2 = 10,
    parameter int          TLB_ENTRIES      = 8,
    parameter int          TX_IFG           = 12,    // Ethernet transmit inter-frame gap, bytes
    parameter bit          RECONFIG         = 1'b1   // software can reload the FPGA from flash (ICAPE2)
) (
    input  wire        sys_clk_p,
    input  wire        sys_clk_n,
    input  wire        sys_rst,         // CPU_RESET button, active high
    output wire [7:0]  LED,
    input  wire [7:0]  GPIO_DIP_SW,
    input  wire [4:0]  GPIO_SW,
    input  wire        UART_RX,
    output wire        UART_TX,

    inout  wire [63:0] ddr3_dq,
    inout  wire [7:0]  ddr3_dqs_n,
    inout  wire [7:0]  ddr3_dqs_p,
    output wire [13:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire        ddr3_reset_n,
    output wire [0:0]  ddr3_ck_p,
    output wire [0:0]  ddr3_ck_n,
    output wire [0:0]  ddr3_cke,
    output wire [0:0]  ddr3_cs_n,
    output wire [7:0]  ddr3_dm,
    output wire [0:0]  ddr3_odt,

    input  wire        sgmii_rxp,
    input  wire        sgmii_rxn,
    output wire        sgmii_txp,
    output wire        sgmii_txn,
    input  wire        sgmii_refclk_p,
    input  wire        sgmii_refclk_n,
    output wire        eth_rst_n,

    // the configuration flash (linear BPI, 16 bits wide). The two address lines above these
    // belong to switch SW11, which picks one of four 32 MiB images.
    output wire [23:0] bpi_addr,        // bit n is flash pin A<n+1>
    inout  wire [15:0] bpi_dq,
    output wire        bpi_ce_n,
    output wire        bpi_oe_n,
    output wire        bpi_we_n,
    output wire        bpi_adv_n
);
  // ------------------------------------------------------------------ memory controller
  // Either the Xilinx memory interface (calibrates itself in hardware) or a LiteDRAM core
  // (fpga/litedram: the boot monitor initialises and levels it through its control port).
  // Both give a controller clock mem_clk, from which the system clocks are derived.
  wire         mem_clk, mem_rst, calib_done;
  wire         mem_req, mem_we, mem_ack;
  wire [23:0]  mem_addr;
  wire [511:0] mem_wdata, mem_rdata;
  wire         dcsr_req, dcsr_we, dcsr_ack;
  wire [13:0]  dcsr_addr;
  wire [31:0]  dcsr_wdata, dcsr_rdata;

  generate if (!LITEDRAM) begin : g_mig
    wire [27:0]  app_addr;
    wire [2:0]   app_cmd;
    wire         app_en, app_wdf_end, app_wdf_wren, app_rd_data_valid, app_rdy, app_wdf_rdy;
    wire [511:0] app_wdf_data, app_rd_data;
    wire [63:0]  app_wdf_mask;

    ddr3_mig u_mig (
        .ddr3_dq, .ddr3_dqs_n, .ddr3_dqs_p, .ddr3_addr, .ddr3_ba, .ddr3_ras_n, .ddr3_cas_n, .ddr3_we_n,
        .ddr3_reset_n, .ddr3_ck_p, .ddr3_ck_n, .ddr3_cke, .ddr3_cs_n, .ddr3_dm, .ddr3_odt,
        .sys_clk_p, .sys_clk_n,
        .app_addr, .app_cmd, .app_en, .app_wdf_data, .app_wdf_end, .app_wdf_mask, .app_wdf_wren,
        .app_rd_data, .app_rd_data_end(), .app_rd_data_valid, .app_rdy, .app_wdf_rdy,
        .app_sr_req(1'b0), .app_ref_req(1'b0), .app_zq_req(1'b0),
        .app_sr_active(), .app_ref_ack(), .app_zq_ack(),
        .ui_clk(mem_clk), .ui_clk_sync_rst(mem_rst), .init_calib_complete(calib_done), .device_temp(),
        .sys_rst
    );
    mig_line_adapter u_adapter (
        .ui_clk(mem_clk), .ui_rst(mem_rst),
        .req(mem_req), .we(mem_we), .line(mem_addr), .wdata(mem_wdata), .ack(mem_ack), .rdata(mem_rdata),
        .app_addr, .app_cmd, .app_en, .app_wdf_data, .app_wdf_end, .app_wdf_mask, .app_wdf_wren,
        .app_rd_data, .app_rd_data_valid, .app_rdy, .app_wdf_rdy
    );
    assign dcsr_ack   = dcsr_req;     // no controller registers
    assign dcsr_rdata = 32'h0;
  end else begin : g_ld
    wire         clk200, init_done;
    wire         cmd_valid, cmd_we, cmd_ready, wd_valid, wd_ready, rd_valid, rd_ready;
    wire [23:0]  cmd_addr;
    wire [511:0] wd_data, rd_data;
    wire [63:0]  wd_we;
    wire [29:0]  wb_adr;
    wire [31:0]  wb_dat_w, wb_dat_r;
    wire [3:0]   wb_sel;
    wire         wb_cyc, wb_stb, wb_we, wb_ack;

    IBUFDS u_ibuf_clk (.I(sys_clk_p), .IB(sys_clk_n), .O(clk200));
    litedram_core u_litedram (
        .clk(clk200), .rst(sys_rst), .pll_locked(), .user_clk(mem_clk), .user_rst(mem_rst),
        .init_done, .init_error(),
        .ddram_a(ddr3_addr), .ddram_ba(ddr3_ba), .ddram_ras_n(ddr3_ras_n), .ddram_cas_n(ddr3_cas_n),
        .ddram_we_n(ddr3_we_n), .ddram_cs_n(ddr3_cs_n), .ddram_dm(ddr3_dm), .ddram_dq(ddr3_dq),
        .ddram_dqs_p(ddr3_dqs_p), .ddram_dqs_n(ddr3_dqs_n), .ddram_clk_p(ddr3_ck_p), .ddram_clk_n(ddr3_ck_n),
        .ddram_cke(ddr3_cke), .ddram_odt(ddr3_odt), .ddram_reset_n(ddr3_reset_n),
        .user_port_native_0_cmd_valid(cmd_valid), .user_port_native_0_cmd_ready(cmd_ready),
        .user_port_native_0_cmd_we(cmd_we), .user_port_native_0_cmd_addr(cmd_addr),
        .user_port_native_0_wdata_valid(wd_valid), .user_port_native_0_wdata_ready(wd_ready),
        .user_port_native_0_wdata_we(wd_we), .user_port_native_0_wdata_data(wd_data),
        .user_port_native_0_rdata_valid(rd_valid), .user_port_native_0_rdata_ready(rd_ready),
        .user_port_native_0_rdata_data(rd_data),
        .wb_ctrl_adr(wb_adr), .wb_ctrl_dat_w(wb_dat_w), .wb_ctrl_dat_r(wb_dat_r), .wb_ctrl_sel(wb_sel),
        .wb_ctrl_cyc(wb_cyc), .wb_ctrl_stb(wb_stb), .wb_ctrl_we(wb_we), .wb_ctrl_ack(wb_ack),
        .wb_ctrl_err(), .wb_ctrl_cti(3'b000), .wb_ctrl_bte(2'b00)
    );
    litedram_line_adapter u_adapter (
        .clk(mem_clk), .rst(mem_rst),
        .req(mem_req), .we(mem_we), .line(mem_addr), .wdata(mem_wdata), .ack(mem_ack), .rdata(mem_rdata),
        .csr_req(dcsr_req), .csr_we(dcsr_we), .csr_addr(dcsr_addr), .csr_wdata(dcsr_wdata),
        .csr_ack(dcsr_ack), .csr_rdata(dcsr_rdata),
        .cmd_addr, .cmd_valid, .cmd_we, .cmd_ready,
        .wdata_data(wd_data), .wdata_we(wd_we), .wdata_valid(wd_valid), .wdata_ready(wd_ready),
        .rdata_data(rd_data), .rdata_valid(rd_valid), .rdata_ready(rd_ready),
        .wb_adr, .wb_dat_w, .wb_sel, .wb_cyc, .wb_stb, .wb_we, .wb_ack, .wb_dat_r
    );
    assign calib_done = init_done;    // set by the monitor when levelling has passed
  end endgenerate

  // ------------------------------------------------------------------ system clocks
  wire clk_sys, clk_mac, clk_fb, clk_sys_u, clk_mac_u, mmcm_locked;
  MMCME2_BASE #(
      .CLKIN1_PERIOD(LITEDRAM ? 10.000 : 5.000), .DIVCLK_DIVIDE(1),
      .CLKFBOUT_MULT_F(LITEDRAM ? 10.000 : 5.000),   // 1 GHz VCO from 100 or 200 MHz
      .CLKOUT0_DIVIDE_F(SYS_DIV), .CLKOUT1_DIVIDE(8)
  ) u_mmcm (
      .CLKIN1(mem_clk), .CLKFBIN(clk_fb), .CLKFBOUT(clk_fb), .CLKFBOUTB(),
      .CLKOUT0(clk_sys_u), .CLKOUT0B(), .CLKOUT1(clk_mac_u), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
      .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
      .LOCKED(mmcm_locked), .PWRDWN(1'b0), .RST(mem_rst)
  );
  BUFG u_bufg_sys (.I(clk_sys_u), .O(clk_sys));
  BUFG u_bufg_mac (.I(clk_mac_u), .O(clk_mac));

  // reset and calibration status into the system clock
  (* ASYNC_REG = "TRUE" *) reg [3:0] rst_sync = 4'hf;
  (* ASYNC_REG = "TRUE" *) reg [1:0] calib_sync = 2'b00;
  always @(posedge clk_sys or negedge mmcm_locked)
    if (!mmcm_locked) rst_sync <= 4'hf;
    else              rst_sync <= {rst_sync[2:0], 1'b0};
  wire rst_sys   = rst_sync[3];
  always @(posedge clk_sys)
    if (rst_sys) calib_sync <= 2'b00;
    else         calib_sync <= {calib_sync[0], calib_done};
  wire ddr_ready = calib_sync[1];   // LED only when LITEDRAM: the core must run to get there

  // ------------------------------------------------------------------ Ethernet PHY and MAC
  wire [7:0]  rx_tdata, tx_tdata;
  wire        rx_tvalid, rx_tlast, rx_tuser, tx_tvalid, tx_tlast, tx_tready;
  wire [15:0] pcspma_status;

  wire eth_rx_clk, eth_rx_rst, eth_tx_clk, eth_tx_rst;
  wire [15:0] tx_pcs_frames;
  legend_sgmii #(.TX_IFG(8'(TX_IFG))) u_eth (
      .clk_int(clk_sys), .rst_int(rst_sys),
      .sgmii_rxp, .sgmii_rxn, .sgmii_txp, .sgmii_txn, .sgmii_refclk_p, .sgmii_refclk_n,
      .phy_reset_n(eth_rst_n),
      .tx_clk(eth_tx_clk), .tx_rst(eth_tx_rst),
      .tx_axis_tdata(tx_tdata), .tx_axis_tvalid(tx_tvalid), .tx_axis_tlast(tx_tlast), .tx_axis_tready(tx_tready),
      .tx_frames_out(tx_pcs_frames),
      .rx_clk(eth_rx_clk), .rx_rst(eth_rx_rst),
      .rx_axis_tdata(rx_tdata), .rx_axis_tvalid(rx_tvalid), .rx_axis_tlast(rx_tlast), .rx_axis_tuser(rx_tuser),
      .pcspma_status(pcspma_status)
  );

  // ------------------------------------------------------------------ the system
  wire [7:0]  soc_led;
  wire [15:0] fl_dq_i, fl_dq_o;
  wire        fl_dq_t, reconfig;
  legend64_soc #(.CLK_HZ(CLK_HZ), .BUILD_ID(BUILD_ID), .BOOT_HEX(BOOT_HEX),
                .CACHE_LINES_LOG2(CACHE_LINES_LOG2), .TLB_ENTRIES(TLB_ENTRIES)) u_soc (
      .clk(clk_sys), .rst(rst_sys), .ddr_ready(ddr_ready || LITEDRAM), .ddr_soft(LITEDRAM),
      .mem_req, .mem_we, .mem_addr, .mem_wdata, .mem_ack, .mem_rdata,
      .dcsr_req, .dcsr_we, .dcsr_addr, .dcsr_wdata, .dcsr_ack, .dcsr_rdata,
      .uart_tx(UART_TX), .uart_rx(UART_RX), .led(soc_led), .dip(GPIO_DIP_SW), .btn(GPIO_SW),
      .mac_clk(eth_rx_clk), .mac_rst(eth_rx_rst), .mac_tx_clk(eth_tx_clk), .mac_tx_rst(eth_tx_rst), .tx_pcs_frames,
      .rx_tdata, .rx_tvalid, .rx_tlast, .rx_tuser, .tx_tdata, .tx_tvalid, .tx_tlast, .tx_tready,
      .pcs_status(pcspma_status),
      .fl_addr(bpi_addr), .fl_dq_i, .fl_dq_o, .fl_dq_t, .fl_ce_n(bpi_ce_n), .fl_oe_n(bpi_oe_n),
      .fl_we_n(bpi_we_n), .fl_adv_n(bpi_adv_n), .reconfig
  );

  genvar gi;
  generate
    for (gi = 0; gi < 16; gi = gi + 1) begin : g_dq
      IOBUF u_iobuf (.IO(bpi_dq[gi]), .I(fl_dq_o[gi]), .T(fl_dq_t), .O(fl_dq_i[gi]));
    end
    if (RECONFIG) begin : g_reconfig
      legend_reconfig u_reconfig (.clk(clk_sys), .rst(rst_sys), .go(reconfig));
    end
  endgenerate

  // LED7 heartbeat on the system clock, LED6 memory calibrated, LED5 Ethernet link, 4:0 software.
  // The heartbeat is held at zero until the clock generator reports lock, so a flashing LED7 says
  // both that the clock runs and that the system reset has been released.
  reg [24:0] hb;
  always @(posedge clk_sys or negedge mmcm_locked)
    if (!mmcm_locked) hb <= 25'd0;
    else              hb <= hb + 1'b1;
  assign LED = {hb[24], ddr_ready, pcspma_status[0], soc_led[4:0]};
endmodule
