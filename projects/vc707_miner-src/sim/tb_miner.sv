// tb_miner.sv -- miner_core end to end, as mine_daemon sees it.
//
// gen_job.py writes a real kHeavyHash job (CONFIG_HDR, then CONFIG_MAT rows
// 0-31 and 32-63, exactly mine_daemon's frames) and the first nonce whose
// hash meets its target.  This bench plays the frames into the MAC's RX
// stream (sgmii_soc_stub.sv), collects every frame the miner transmits, and
// passes when it has ACKed all three config frames and reported that nonce
// in a NONCE_FOUND frame.
//
//   +job=<dir>       gen_job.py output (default .)
//   +tx_stall        hold tx_ready low 1 cycle in 3 (MAC back-pressure)

`timescale 1ns/1ps
`default_nettype none

module tb_miner;
  // ---- clocks: clk_mac 100 MHz, clk_sys 50 MHz ----
  logic clk_mac = 0, clk_sys = 0;
  always #5  clk_mac = ~clk_mac;
  always #10 clk_sys = ~clk_sys;

  logic rst_mac_n = 0, resetn = 0;

  // ---- the MAC's AXI streams (read by sgmii_soc_stub) ----
  logic [7:0] rx_tdata = 0;
  logic       rx_tvalid = 0, rx_tlast = 0;
  logic       tx_ready = 1;

  wire [15:0] pcspma_status;
  wire        led_mining, led_found, hh_busy;
  wire        sgmii_txp, sgmii_txn, eth_rst_n;

`ifdef GATE
  miner_core dut (
`else
  miner_core #(.LANES(1)) dut (
`endif
    .clk_mac(clk_mac), .rst_mac_n(rst_mac_n), .clk_sys(clk_sys), .resetn(resetn),
    .sgmii_rxp(1'b0), .sgmii_rxn(1'b1), .sgmii_txp(sgmii_txp), .sgmii_txn(sgmii_txn),
    .sgmii_refclk_p(1'b0), .sgmii_refclk_n(1'b1), .eth_rst_n(eth_rst_n),
    .pcspma_status(pcspma_status), .led_mining(led_mining), .led_found(led_found),
    .hh_busy(hh_busy));

`ifdef UNISIM
  glbl glbl ();   // Vivado unisim models (RAMB36E1) refer to glbl.GSR
`endif

  // ---- job ----
  logic [7:0]  frame_bytes [0:8191];
  integer      frame_len [0:7];
  integer      nframes;
  logic [63:0] nonce_start, nonce_expect;
  string       job;

  initial begin
    integer fd, n, l;
    if (!$value$plusargs("job=%s", job)) job = ".";
    $readmemh({job, "/frames.hex"}, frame_bytes);
    fd = $fopen({job, "/frames.len"}, "r");
    nframes = 0;
    while (!$feof(fd)) begin
      n = $fscanf(fd, "%d\n", l);
      if (n == 1) begin frame_len[nframes] = l; nframes = nframes + 1; end
    end
    $fclose(fd);
    fd = $fopen({job, "/expect.txt"}, "r");
    n = $fscanf(fd, "%d %d", nonce_start, nonce_expect);
    $fclose(fd);
    $display("tb: %0d frames, nonce_start %h, expect nonce %h", nframes, nonce_start, nonce_expect);
  end

  // ---- TX monitor: reassemble frames, decode the 0x4B41 ones ----
  logic [7:0] txb [0:2047];
  integer     txn = 0;
  integer     acks = 0, naks = 0, nonces = 0, heartbeats = 0;
  logic [7:0] ack_seq [0:15];
  logic [63:0] found_nonce;
  logic       tx_stall = 0;

  initial tx_stall = $test$plusargs("tx_stall");
  integer stall_cnt = 0;
  always @(posedge clk_mac) begin
    stall_cnt <= stall_cnt + 1;
    tx_ready  <= !(tx_stall && (stall_cnt % 3 == 0));
  end

  // sgmii_soc_stub calls this for every byte the MAC takes (so it works on
  // the flattened netlist too, where dut.u_framing.eth is not a scope)
  task automatic tx_byte(input logic [7:0] d, input logic last);
    txb[txn] = d;
    txn = txn + 1;
    if (last) begin
      decode_tx(txn);
      txn = 0;
    end
  endtask

  task automatic decode_tx(input integer len);
    logic [63:0] v;
    if (len < 16 || txb[12] != 8'h4B || txb[13] != 8'h41)
      $display("tb: TX frame of %0d bytes, not 0x4B41", len);
    else case (txb[14])
      8'h03: begin
        v = '0;
        for (int i = 0; i < 8; i++) v[i*8 +: 8] = txb[16+i];
        found_nonce = v;
        nonces = nonces + 1;
        $display("tb: %0t NONCE_FOUND %h (%0d bytes)", $time, v, len);
      end
      8'h04: begin
        v = '0;
        for (int i = 0; i < 8; i++) v[i*8 +: 8] = txb[16+i];
        heartbeats = heartbeats + 1;
        $display("tb: %0t HEARTBEAT hash_count %0d status %h", $time, v, txb[24]);
      end
      8'h05: begin naks = naks + 1; $display("tb: %0t NAK seq %0d", $time, txb[15]); end
      8'h06: begin
        if (acks < 16) ack_seq[acks] = txb[15];
        acks = acks + 1;
        $display("tb: %0t ACK seq %0d", $time, txb[15]);
      end
      default: $display("tb: %0t frame type %h", $time, txb[14]);
    endcase
    // destination is the host's MAC, learned from what it sent
    if ({txb[0], txb[1], txb[2], txb[3], txb[4], txb[5]} != 48'h02000000aa01)
      $display("tb: WARNING TX destination %h", {txb[0], txb[1], txb[2], txb[3], txb[4], txb[5]});
  endtask

  // ---- stimulus ----
  task automatic send_frame(input integer base, input integer len);
    for (int i = 0; i < len; i++) begin
      @(posedge clk_mac);
      rx_tdata  <= frame_bytes[base + i];
      rx_tvalid <= 1'b1;
      rx_tlast  <= (i == len - 1);
    end
    @(posedge clk_mac);
    rx_tvalid <= 1'b0;
    rx_tlast  <= 1'b0;
    repeat (24) @(posedge clk_mac);    // preamble + IFG
  endtask

  initial begin
    integer base;
    bit pass;
    repeat (20) @(posedge clk_sys);
    resetn = 1;
    repeat (10) @(posedge clk_mac);
    rst_mac_n = 1;
    repeat (200) @(posedge clk_mac);   // mine_ctrl S_INIT
    base = 0;
    for (int f = 0; f < nframes; f++) begin
      send_frame(base, frame_len[f]);
      base = base + frame_len[f];
      // as mine_daemon: wait for this frame's ACK before the next
      fork : wait_ack
        begin wait (acks > f); end
        begin repeat (20000) @(posedge clk_mac); end
      join_any
      disable wait_ack;
    end
    fork : wait_nonce
      begin wait (nonces > 0); end
      begin repeat (200000) @(posedge clk_mac); end
    join_any
    disable wait_nonce;
    repeat (100) @(posedge clk_mac);

    pass = acks == nframes && naks == 0 && nonces == 1 && found_nonce == nonce_expect;
    for (int i = 0; i < nframes && i < 16; i++)
      if (ack_seq[i] != frame_bytes_seq(i)) pass = 0;
    $display("tb: acks %0d/%0d naks %0d nonces %0d heartbeats %0d mining %b found %b",
             acks, nframes, naks, nonces, heartbeats, led_mining, led_found);
    if (nonces) $display("tb: found %h expected %h", found_nonce, nonce_expect);
    if (pass) $display("tb: PASS");
    else      $display("tb: FAIL");
    $finish;
  end

  // the seq byte (offset 15) of frame i
  function automatic logic [7:0] frame_bytes_seq(input integer i);
    integer b = 0;
    for (int k = 0; k < i; k++) b += frame_len[k];
    return frame_bytes[b + 15];
  endfunction

  initial begin
    #50ms;
    $display("tb: TIMEOUT");
    $finish;
  end
endmodule

`default_nettype wire
