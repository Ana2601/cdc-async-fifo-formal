RTL   := rtl/cdc_sync.sv rtl/async_fifo.sv
BUILD := build
# wclk:rclk periods in ps - equal, near-equal, non-integer, and 7x in either direction
RATIOS := 10000:10000 10000:10370 10000:13000 6400:10000 10000:31416 31416:10000 10000:70000 70000:10000

.PHONY: test formal lint synth clean

test:
	@mkdir -p $(BUILD)
	iverilog -g2012 -o $(BUILD)/tb.vvp $(RTL) tb/tb_cdc.sv
	@for r in $(RATIOS); do w=$${r%%:*}; rr=$${r##*:}; \
	  vvp -n $(BUILD)/tb.vvp +wper=$$w +rper=$$rr > $(BUILD)/run.log; \
	  grep -E "ratio|ERROR|FAIL" $(BUILD)/run.log; grep -q "TEST PASSED" $(BUILD)/run.log || exit 1; done
	@echo "TEST PASSED (all clock ratios)"

formal:
	cd formal && sby -f async_fifo.sby

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-MULTITOP $(RTL)

synth:
	@mkdir -p $(BUILD)
	yosys -q -p "read_verilog -sv $(RTL); synth -top async_fifo; tee -o $(BUILD)/synth_stat.txt stat"

clean:
	rm -rf $(BUILD) formal/async_fifo_bmc formal/async_fifo_cover
