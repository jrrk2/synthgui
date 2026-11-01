# vc707_miner sources

A kHeavyHash (Kaspa) miner for the VC707, built with the open flow alone:
verilator `synthesis` branch, then nextpnr-himbaechel, then prjxray. There is no Xilinx IP. The
SGMII PCS/PHY is LiteEth's, from `vc707_ethmin`. Mining is controlled with raw
EtherType 0x4B41 frames by `mine_daemon` (`~/heavyhash/mine_daemon`), which
gets block templates from kaspad over wRPC and submits the blocks found.

```
vc707_miner      clkgen_vc707 (clk_sys = 1 GHz / SYS_DIV, clk_mac = 1 GHz / MAC_DIV), reset, LEDs
 └ miner_core    one clock (clk_mac) for everything below
    ├ framing_miner   frame buffers + mine_ctrl's register map
    │  └ sgmii_soc    LiteEth PCS + GTXE2 + eth_mac_1g (sgmii_soc_liteeth.sv)
    ├ mine_ctrl       CONFIG_HDR / CONFIG_MAT in; ACK, NAK, NONCE_FOUND, HEARTBEAT out
    └ heavyhash_multi `LANES lanes (heavyhash_pipeline: 2 x keccak256 + heavyhash_matrix)
```

Defines (`projects/vc707_miner.json`): `LANES` (1), `MAC_DIV` (10, so 100 MHz), `SYS_DIV` (20, so 50 MHz).
mine_ctrl's heartbeat interval is 12.5M clk_mac cycles, which is 125 ms at 100 MHz.

LEDs: 0 mining, 1 found, 2 link up, 3 lanes busy, 4 PCS clocks locked,
5 an RX frame was seen, 6 clk_mac heartbeat, 7 clk_sys heartbeat (fast while in reset).

## Where the files come from

| here | from | changes |
|---|---|---|
| keccak_pkg.sv, keccak_round.sv, keccak256.sv, heavyhash_pkg.sv, heavyhash_matrix.sv, heavyhash_pipeline.sv, heavyhash_multi.sv, mine_ctrl.sv | `~/heavyhash`, identical to `~/cva6` cb702b40 `corev_apu/fpga/src/heavyhash/` | none |
| liteeth_sgmii_phy.v, sgmii_soc_liteeth.sv, eth_gmii_retime256.sv, eth_pkt_buf256.sv, eth_mac_1g.sv, axis_gmii_rx.sv, axis_gmii_tx.sv, rgmii_lfsr.sv, clkgen_vc707.sv | `vc707_ethmin-src` | none |
| framing_miner.sv | `~/cva6` cb702b40 `framing_top_sgmii.sv` | rewritten for one clock, inferred block RAM, and the LiteEth `sgmii_soc`; the register map is unchanged (see its header) |
| miner_core.sv, vc707_miner.sv, vc707_miner_open.xdc | new; the XDC pins and LOCs are from `vc707_ethmin_vm_open.xdc` | |
| sim/RAMB36E1.v | `~/heavyhash/sim` | none |

## Tests

* `sim/run.sh`: the RTL end to end. `gen_job.py` uses `~/heavyhash/verify_pow.py` to
  compute a real job and the first nonce in it whose hash meets the target. `tb_miner.sv`
  plays mine_daemon's three config frames into the MAC's RX stream (`sgmii_soc_stub.sv` replaces the
  PCS). It passes when all three frames are ACKed and NONCE_FOUND reports that nonce.
  `+tx_stall` adds TX back-pressure.
* `sim/run_gate.sh`: the same test on the verilator synthesis branch's mapped netlist of
  `miner_core`, in iverilog (about 3 min). `--rtl-lanes` keeps the hashing lanes in RTL
  (about 1 min). It uses Vivado's unisim RAMB36E1, because the RAMB36E1 in `xc7/cells_sim.v` is a
  timing-only stub that reads `z`.

Both tests passed on 2026-11-01.

## On the board

* `sim/hw_probe.py <iface>` runs the tb_miner test over real Ethernet. It needs a raw
  socket, so run it with sudo.
* `host/ws_tls_relay.py` lets `mine_daemon`, which speaks plain `ws://`, reach a public
  kaspad that only serves `wss://`:

```
python3 -I host/ws_tls_relay.py 18210 vector-10.kaspa.green &
mine_daemon --iface eno1 --kaspad ws://127.0.0.1:18210/kaspa/testnet-10/wrpc/json --wallet kaspatest:...
```

  For other testnet-10 nodes, ask a public resolver (for example
  `https://eric.kaspa.stream/v2/kaspa/testnet-10/tls/wrpc/borsh`). The node it returns
  also serves `/wrpc/json`.

Tested on 2026-11-01 with 1 lane at `MAC_DIV=10` (100 MHz). The board was loaded over JTAG.
P&R met timing on every clock (clk_mac Fmax 125.2 MHz). The board mined testnet-10 at
2.0-2.3 MH/s. In a 60 s run it found 38 nonces; all passed mine_daemon's software check,
and kaspad accepted all 38 blocks (`{"type":"success"}`).
