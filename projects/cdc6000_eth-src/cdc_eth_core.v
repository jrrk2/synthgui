// cdc_eth_core -- the CDC 6000 core (rtl/cdc6000_core.sv) with the ethmin Ethernet device behind its device window.
//
// Same register semantics as ethmin_vm_core.v (fpga/vc707-ethmin), one byte per 60 bit word: the core's loads and stores to
// DEV_BASE+off (off 0..0x100F) arrive on the dev_* bus; the packet RAM (2 KiB RX window, 2 KiB TX window) is shared with
// eth_stream_dma, which owns it between frames.
//
//   0x0000..0x07FF RX window   0x0800..0x0FFF TX window
//   0x1000 r {rx_trunc, tx_busy, rx_valid}   0x1001 r PCS/PMA status   0x1002 r received length, w release the RX window
//   0x1003 w length: send the TX window   0x1004 rw LEDs   0x1005 w console byte (UART)   0x1006 r milliseconds
//   0x1008 r console input: 256 + byte, and the byte is taken from a 64 byte FIFO; 0 when it is empty
//   0x1009 r DIP switches   0x100a r free running clock cycle count (32 bits)   0x100b r push buttons
//   0x100c w ramdisk byte address, r its size in KB (0: no ramdisk)   0x100d rw the byte at that address, then the address + 1
//
// The ramdisk (cdc_disk_bram, gendisk.py: block RAM holding a small file system with the compiler's files) takes the
// network out of a compile: see nfs/README.md.  Its read data is two clocks behind its address; the core's accesses
// are at least four clocks apart (D_ACK, D_DROP, dev_cool), so the byte of the address written or stepped by the
// previous access is always there.
//
// The memory of the core is initialised from mem.hex (runtime + program + NFS driver: see mkmem.py).
`default_nettype none
module cdc_eth_core #(
	parameter integer CLK_HZ = 50_000_000,
	parameter integer BAUD   = 115_200,
	parameter integer CORE_SB = 0          // 1: the scoreboarded core (rtl/cdc6000_sb.sv), 0: the sequential one
) (
	input  wire        clk_sys,
	input  wire        resetn,
	input  wire [7:0]  DIP,
	input  wire [4:0]  BTN,
	input  wire        eth_clk,
	input  wire        eth_rst,

	input  wire [7:0]  rx_axis_tdata,
	input  wire        rx_axis_tvalid,
	input  wire        rx_axis_tlast,
	input  wire        rx_axis_tuser,
	output wire [7:0]  tx_axis_tdata,
	output wire        tx_axis_tvalid,
	output wire        tx_axis_tlast,
	input  wire        tx_axis_tready,
	output wire        tx_axis_tuser,

	input  wire [15:0] pcspma_status,
	output wire [7:0]  LED,
	input  wire        UART_RX,
	output wire        UART_TX,
	output wire        halted,
	output wire        fault
);
	// ─── the DMA: MAC stream <-> packet RAM port B ───────────────────────
	wire        mem_b_en, mem_b_we;
	wire [13:0] mem_b_addr;
	wire [31:0] mem_b_wdata;
	wire [31:0] mem_b_rdata;
	wire        rx_valid /*verilator public_flat_rd*/, rx_trunc, tx_busy;
	wire [10:0] rx_len;
	reg  [10:0] tx_len;
	reg         tx_start, rx_ack;

	eth_stream_dma #(.RX_WORD_BASE(14'd0), .TX_WORD_BASE(14'd512), .WINDOW_WORDS(512)) dma (
		.eth_clk(eth_clk), .eth_rst(eth_rst),
		.rx_axis_tdata(rx_axis_tdata), .rx_axis_tvalid(rx_axis_tvalid),
		.rx_axis_tlast(rx_axis_tlast), .rx_axis_tuser(rx_axis_tuser),
		.tx_axis_tdata(tx_axis_tdata), .tx_axis_tvalid(tx_axis_tvalid),
		.tx_axis_tlast(tx_axis_tlast), .tx_axis_tready(tx_axis_tready),
		.tx_axis_tuser(tx_axis_tuser),
		.mem_en(mem_b_en), .mem_we(mem_b_we), .mem_addr(mem_b_addr),
		.mem_wdata(mem_b_wdata), .mem_rdata(mem_b_rdata),
		.cpu_clk(clk_sys), .cpu_rst(~resetn),
		.rx_valid(rx_valid), .rx_len(rx_len), .rx_trunc(rx_trunc),
		.rx_ack(rx_ack), .tx_len(tx_len), .tx_start(tx_start),
		.tx_busy(tx_busy));

	// ─── packet RAM: one byte-wide two-port RAM per lane (as ethmin_vm_core.v) ───
	reg         pa_en;
	reg  [3:0]  pa_we;
	reg  [9:0]  pa_addr;
	reg  [31:0] pa_wdata;
	wire [31:0] pa_rdata;
	genvar lane;
	generate
		for (lane = 0; lane < 4; lane = lane + 1) begin : pkt_lane
			reg [7:0] mem [0:1023];
			reg [7:0] b_q, a_q;
			always @(posedge eth_clk)
				if (mem_b_en) begin
					if (mem_b_we) mem[mem_b_addr[9:0]] <= mem_b_wdata[8*lane +: 8];
					else b_q <= mem[mem_b_addr[9:0]];
				end
			always @(posedge clk_sys)
				if (pa_en) begin
					if (pa_we[lane]) mem[pa_addr] <= pa_wdata[8*lane +: 8];
					else a_q <= mem[pa_addr];
				end
			assign mem_b_rdata[8*lane +: 8] = b_q;
			assign pa_rdata[8*lane +: 8] = a_q;
		end
	endgenerate

	// ─── millisecond timer ───────────────────────────────────────────────
	localparam integer MS_DIV = CLK_HZ / 1000;
	localparam integer MS_W   = $clog2(MS_DIV);
	reg [MS_W-1:0] ms_prescale;
	reg [29:0] ms_count;
	always @(posedge clk_sys)
		if (!resetn) begin ms_prescale <= {MS_W{1'b0}}; ms_count <= 30'd0; end
		else if (ms_prescale == MS_DIV - 1) begin ms_prescale <= {MS_W{1'b0}}; ms_count <= ms_count + 30'd1; end
		else ms_prescale <= ms_prescale + 1'b1;

	// ─── console UART: the program writes 0x1005 and reads the receive FIFO at 0x1008 ───
	wire uart_wait;
	wire [31:0] uart_rdo;
	reg  rx_s1, rx_s2;
	always @(posedge clk_sys) begin rx_s1 <= UART_RX; rx_s2 <= rx_s1; end
	// receive FIFO: a byte the UART has is moved here at once (the program may be busy for milliseconds)
	reg [7:0] rxf [0:63];
	reg [6:0] rxf_wr, rxf_rd;
	wire rxf_full = (rxf_wr - rxf_rd) == 7'd64;
	wire rxf_empty = rxf_wr == rxf_rd;
	wire rx_push = !uart_rdo[8] && !rxf_full && resetn;
	reg  rxf_pop;
	always @(posedge clk_sys) begin
		if (!resetn) begin rxf_wr <= 7'd0; rxf_rd <= 7'd0; end
		else begin
			if (rx_push) begin rxf[rxf_wr[5:0]] <= uart_rdo[7:0]; rxf_wr <= rxf_wr + 7'd1; end
			if (rxf_pop && !rxf_empty) rxf_rd <= rxf_rd + 7'd1;
		end
	end
	reg [31:0] cyc;
	always @(posedge clk_sys) cyc <= resetn ? cyc + 32'd1 : 32'd0;

	// ─── the ramdisk: 0x100c address (read: size), 0x100d the byte there, stepping the address ───
	reg  [19:0] disk_addr;
	reg         disk_we;
	reg  [7:0]  disk_wdata;
	wire [7:0]  disk_q;
	wire [15:0] disk_kb;
	cdc_disk_bram disk (.clk(clk_sys), .we(disk_we), .addr(disk_addr), .din(disk_wdata), .dout(disk_q), .size_kb(disk_kb));
	reg  uart_we;
	reg  [7:0] uart_byte;
	simpleuart #(.DEFAULT_DIV(CLK_HZ / BAUD)) uart (
		.clk(clk_sys), .resetn(resetn), .ser_tx(UART_TX), .ser_rx(rx_s2),
		.reg_div_we(4'b0000), .reg_div_di(32'd0), .reg_div_do(),
		.reg_dat_we(uart_we), .reg_dat_re(rx_push), .reg_dat_di({24'd0, uart_byte}), .reg_dat_do(uart_rdo),
		.reg_dat_wait(uart_wait));

	reg [7:0] dip_s1, dip_s2;
	reg [4:0] btn_s1, btn_s2;
	always @(posedge clk_sys) begin dip_s1 <= DIP; dip_s2 <= dip_s1; btn_s1 <= BTN; btn_s2 <= btn_s1; end

	// ─── the core ────────────────────────────────────────────────────────
	wire        dev_req, dev_we;
	wire [12:0] dev_off;
	wire [59:0] dev_wdata;
	reg         dev_ack;
	reg  [59:0] dev_rdata;
	wire [17:0] dbg_pc;
	wire [63:0] icount;

	wire [15:0] ext_addr, ext_iaddr;
	wire        ext_we;
	wire [59:0] ext_wdata, ext_rdata, ext_irdata;
	wire [479:0] dbg_x;
	wire [143:0] dbg_a, dbg_b;
	cdc_ram_bram ram (.clk(clk_sys), .en(1'b1), .we(ext_we), .addr(ext_addr), .din(ext_wdata), .dout(ext_rdata),
		.iaddr(ext_iaddr), .idout(ext_irdata));

	generate if (CORE_SB) begin : g_sb
		cdc6000_sb #(.MEM_AW(16), .EXT_MEM(1'b1)) core (
			.clk(clk_sys), .reset(!resetn),
			.ext_iaddr(ext_iaddr), .ext_irdata(ext_irdata),
			.ext_addr(ext_addr), .ext_we(ext_we), .ext_wdata(ext_wdata), .ext_rdata(ext_rdata),
			.load_we(1'b0), .load_addr(16'd0), .load_data(60'd0),
			.rx_valid(1'b0), .rx_char(6'd0), .rx_eof(1'b1), .rx_take(),
			.tx_valid(), .tx_char(), .tx_ready(1'b1),
			.fo_valid(), .fo_name(), .fo_word(), .fo_ready(1'b1),
			.dev_req(dev_req), .dev_we(dev_we), .dev_off(dev_off), .dev_wdata(dev_wdata),
			.dev_ack(dev_ack), .dev_rdata(dev_rdata),
			.halted(halted), .fault(fault), .dbg_pc(dbg_pc), .icount(icount),
			.dbg_x(dbg_x), .dbg_a(dbg_a), .dbg_b(dbg_b), .dbg_perf());
	end else begin : g_seq
		assign ext_iaddr = 16'd0;
		cdc6000_core #(.MEM_AW(16), .EXT_MEM(1'b1)) core (
			.clk(clk_sys), .reset(!resetn),
			.ext_addr(ext_addr), .ext_we(ext_we), .ext_wdata(ext_wdata), .ext_rdata(ext_rdata),
			.load_we(1'b0), .load_addr(17'd0), .load_data(60'd0),
			.rx_valid(1'b0), .rx_char(6'd0), .rx_eof(1'b1), .rx_take(),
			.tx_valid(), .tx_char(), .tx_ready(1'b1),
			.fo_valid(), .fo_name(), .fo_word(), .fo_ready(1'b1),
			.dev_req(dev_req), .dev_we(dev_we), .dev_off(dev_off), .dev_wdata(dev_wdata),
			.dev_ack(dev_ack), .dev_rdata(dev_rdata),
			.halted(halted), .fault(fault), .dbg_pc(dbg_pc), .icount(icount),
			.dbg_x(dbg_x), .dbg_a(dbg_a), .dbg_b(dbg_b));
	end endgenerate

	// ─── the device bus ──────────────────────────────────────────────────
	localparam [2:0] D_IDLE = 3'd0, D_PKT = 3'd1, D_ACK = 3'd2, D_DROP = 3'd3, D_UART = 3'd4, D_DISKW = 3'd5;
	reg [2:0] dstate;
	reg [1:0] dlane;
	reg [7:0] leds;
	wire is_pkt = dev_off < 13'h1000;
	always @(*) begin
		pa_en = 1'b0; pa_we = 4'b0000; pa_addr = dev_off[11:2]; pa_wdata = {4{dev_wdata[7:0]}};
		if (dstate == D_IDLE && dev_req && is_pkt) begin
			pa_en = 1'b1;
			if (dev_we) pa_we = 4'b0001 << dev_off[1:0];
		end
	end
	always @(posedge clk_sys) begin
		dev_ack <= 1'b0; rx_ack <= 1'b0; tx_start <= 1'b0; rxf_pop <= 1'b0;
		disk_we <= 1'b0;
		if (!resetn) begin dstate <= D_IDLE; leds <= 8'd0; tx_len <= 11'd0; uart_we <= 1'b0; disk_addr <= 20'd0; end
		else case (dstate)
			D_IDLE: if (dev_req) begin
				dlane <= dev_off[1:0];
				if (is_pkt) begin
					if (dev_we) begin dev_ack <= 1'b1; dstate <= D_ACK; end
					else dstate <= D_PKT;
				end else if (dev_we) begin
					case (dev_off)
						13'h1002: rx_ack <= 1'b1;
						13'h1003: begin tx_len <= dev_wdata[10:0]; tx_start <= 1'b1; end
						13'h1004: leds <= dev_wdata[7:0];
						13'h1005: begin uart_byte <= dev_wdata[7:0]; uart_we <= 1'b1; dstate <= D_UART; end
						13'h100c: disk_addr <= dev_wdata[19:0];
						13'h100d: begin disk_wdata <= dev_wdata[7:0]; disk_we <= 1'b1; dstate <= D_DISKW; end
						default: ;
					endcase
					if (dev_off != 13'h1005 && dev_off != 13'h100d) begin dev_ack <= 1'b1; dstate <= D_ACK; end
				end else begin
					case (dev_off)
						13'h1000: dev_rdata <= {57'd0, rx_trunc, tx_busy, rx_valid};
						13'h1001: dev_rdata <= {44'd0, pcspma_status};
						13'h1002: dev_rdata <= {49'd0, rx_len};
						13'h1004: dev_rdata <= {52'd0, leds};
						13'h1006: dev_rdata <= {30'd0, ms_count};
						// pop only what is read now: a byte pushed in this very cycle is not in dev_rdata, and an unconditional pop
						// the next cycle would discard it (it did: about one byte in 25 typed into the shell was lost)
						13'h1008: begin dev_rdata <= rxf_empty ? 60'd0 : {51'd0, 1'b1, rxf[rxf_rd[5:0]]}; rxf_pop <= !rxf_empty; end
						13'h100a: dev_rdata <= {28'd0, cyc};
						13'h1009: dev_rdata <= {52'd0, dip_s2};
						13'h100b: dev_rdata <= {55'd0, btn_s2};
						13'h100c: dev_rdata <= {44'd0, disk_kb};
						13'h100d: begin dev_rdata <= {52'd0, disk_q}; disk_addr <= disk_addr + 20'd1; end
						default:  dev_rdata <= 60'd0;
					endcase
					dev_ack <= 1'b1; dstate <= D_ACK;
				end
			end
			D_PKT: begin                                   // the byte lane of the word read last cycle
				dev_rdata <= {52'd0, pa_rdata[8*dlane +: 8]};
				dev_ack <= 1'b1; dstate <= D_ACK;
			end
			D_UART: if (!uart_wait) begin uart_we <= 1'b0; dev_ack <= 1'b1; dstate <= D_ACK; end
			D_DISKW: begin disk_addr <= disk_addr + 20'd1; dev_ack <= 1'b1; dstate <= D_ACK; end   // the byte was written this clock
			D_ACK: dstate <= D_DROP;                       // dev_ack was high this cycle: the core is leaving S_DEV
			D_DROP: if (!dev_req) dstate <= D_IDLE;
			default: dstate <= D_IDLE;
		endcase
	end
	assign LED = {halted, fault, leds[5:0]};
endmodule
`default_nettype wire
