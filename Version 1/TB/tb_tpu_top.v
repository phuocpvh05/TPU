`timescale 1ns / 1ps

module tb_tpu_top;

    // ---- Parameters ----
    parameter ARRAY_SIZE        = 4;
    parameter SRAM_DATA_WIDTH   = 32;
    parameter DATA_WIDTH        = 8;
    parameter OUTPUT_DATA_WIDTH = 16;

    // ---- DUT signals ----
    reg  clk, rst_n, tpu_start;
    wire [SRAM_DATA_WIDTH-1:0]              sram_rdata_w;
    wire [SRAM_DATA_WIDTH-1:0]              sram_rdata_d;
    wire [3:0]                              sram_raddr_w;
    wire [3:0]                              sram_raddr_d;
    
    wire                                    sram_write_enable_a0;
    wire [ARRAY_SIZE*OUTPUT_DATA_WIDTH-1:0] sram_wdata_a;
    wire [2:0]                              sram_waddr_a;
    
    wire                                    sram_write_enable_b0;
    wire [ARRAY_SIZE*OUTPUT_DATA_WIDTH-1:0] sram_wdata_b;
    wire [2:0]                              sram_waddr_b;
    
    wire                                    sram_write_enable_c0;
    wire [ARRAY_SIZE*OUTPUT_DATA_WIDTH-1:0] sram_wdata_c;
    wire [2:0]                              sram_waddr_c;
    wire tpu_done;

    // ---- Mock SRAM (BRAM 1-cycle latency) ----
    reg [SRAM_DATA_WIDTH-1:0] weight_mem [0:15];
    reg [SRAM_DATA_WIDTH-1:0] data_mem   [0:15];

    reg [SRAM_DATA_WIDTH-1:0] sram_rdata_w_reg;
    reg [SRAM_DATA_WIDTH-1:0] sram_rdata_d_reg;

    always @(posedge clk) begin
        sram_rdata_w_reg <= (sram_raddr_w <= 4'd6) ? weight_mem[sram_raddr_w] : 32'h0;
        sram_rdata_d_reg <= (sram_raddr_d <= 4'd6) ? data_mem[sram_raddr_d]   : 32'h0;
    end

    assign sram_rdata_w = sram_rdata_w_reg;
    assign sram_rdata_d = sram_rdata_d_reg;

    // ---- UUT ----
    tpu_top #(
        .ARRAY_SIZE       (ARRAY_SIZE),
        .SRAM_DATA_WIDTH  (SRAM_DATA_WIDTH),
        .DATA_WIDTH       (DATA_WIDTH),
        .OUTPUT_DATA_WIDTH(OUTPUT_DATA_WIDTH)
    ) uut (
        .clk                 (clk),
        .rst_n               (rst_n),
        .tpu_start           (tpu_start),
        .sram_rdata_w        (sram_rdata_w),
        .sram_rdata_d        (sram_rdata_d),
        .sram_raddr_w        (sram_raddr_w),
        .sram_raddr_d        (sram_raddr_d),
        .sram_write_enable_a0(sram_write_enable_a0),
        .sram_wdata_a        (sram_wdata_a),
        .sram_waddr_a        (sram_waddr_a),
        .sram_write_enable_b0(sram_write_enable_b0),
        .sram_wdata_b        (sram_wdata_b),
        .sram_waddr_b        (sram_waddr_b),
        .sram_write_enable_c0(sram_write_enable_c0),
        .sram_wdata_c        (sram_wdata_c),
        .sram_waddr_c        (sram_waddr_c),
        .tpu_done            (tpu_done)
    );

    // ---- Clock 100 MHz ----
    initial clk = 0;
    always  #5 clk = ~clk;

    // ---- Capture BANK A anti-diagonal outputs ----
    reg [ARRAY_SIZE*OUTPUT_DATA_WIDTH-1:0] result_bank_a [0:7];
    integer i, j, k;

    initial begin
        for (i = 0; i < 8; i = i + 1)
            result_bank_a[i] = 0;
    end

    always @(posedge clk) begin
        if (sram_write_enable_a0)
            result_bank_a[sram_waddr_a] <= sram_wdata_a;
    end

    // ---- Data Formatting & Generation ----
    integer A [0:3][0:3];
    integer B [0:3][0:3];
    integer exp_C [0:3][0:3];
    integer got_C [0:3][0:3];

    reg timeout_flag;
    reg done_flag;
    integer pass_cnt, fail_cnt;
    integer d, r, c;
    
    integer T, diff;
    reg [31:0] word_A, word_B;

    initial begin
        // Init
        rst_n        = 0;
        tpu_start    = 0;
        timeout_flag = 0;
        done_flag    = 0;
        pass_cnt     = 0;
        fail_cnt     = 0;

        // 1. Tạo ma trận gốc (Flat Matrices)
        for (i = 0; i < 4; i = i + 1) begin
            for (j = 0; j < 4; j = j + 1) begin
                A[i][j] = i*4 + j + 1;           // Data: 1 đến 16
                B[i][j] = (i == j) ? 1 : 0;      // Weight: Ma trận đơn vị (Identity)
            end
        end

        // 2. Tính toán Software Expected C = A * B
        for (i = 0; i < 4; i = i + 1) begin
            for (j = 0; j < 4; j = j + 1) begin
                exp_C[i][j] = 0;
                for (k = 0; k < 4; k = k + 1) begin
                    exp_C[i][j] = exp_C[i][j] + A[i][k] * B[k][j];
                end
            end
        end

        // 3. Data Skewing (Làm lệch pha dữ liệu để nạp vào SRAM)
        // Hệ thống cần 2N-1 = 7 chu kỳ nạp dữ liệu.
        for (T = 0; T < 16; T = T + 1) begin
            data_mem[T]   = 32'h0;
            weight_mem[T] = 32'h0;
        end

        for (T = 0; T < 7; T = T + 1) begin
            word_A = 32'h0;
            word_B = 32'h0;
            for (i = 0; i < 4; i = i + 1) begin
                diff = T - i;
                if (diff >= 0 && diff < 4) begin
                    // Data chảy ngang -> Cột bị trễ theo hàng (T - i)
                    word_A[31 - i*8 -: 8] = A[i][diff];
                    // Weight chảy dọc -> Hàng bị trễ theo cột (T - i)
                    word_B[31 - i*8 -: 8] = B[diff][i];
                end
            end
            data_mem[T]   = word_A;
            weight_mem[T] = word_B;
        end

        $display("=== EXPECTED C = A * B ===");
        for (i = 0; i < 4; i = i + 1)
            $display("  Row %0d: [%4d, %4d, %4d, %4d]",
                i, exp_C[i][0], exp_C[i][1], exp_C[i][2], exp_C[i][3]);
        $display("");

        // ---- Chạy Hệ Thống ----
        #20;
        rst_n = 1;
        #20;

        $display("=== STARTING 4x4 TPU SIMULATION ===");
        tpu_start = 1;
        #10;
        tpu_start = 0;

        // ---- Đợi hoàn thành ----
        begin : wait_done
            integer timeout_cnt;
            timeout_cnt = 0;
            while (done_flag == 0 && timeout_flag == 0) begin
                @(posedge clk);
                if (tpu_done)
                    done_flag = 1;
                timeout_cnt = timeout_cnt + 1;
                if (timeout_cnt >= 500) begin
                    timeout_flag = 1;
                    $display("!!! TIMEOUT after 500 cycles !!!");
                end
            end
        end

        if (done_flag) begin
            $display("=== TPU SIMULATION COMPLETE ===");
            #20;
        end

        // ---- Decode kết quả chéo (Anti-diagonals) ----
        for (d = 0; d < 7; d = d + 1) begin
            if (d < 4) begin
                for (r = 0; r <= d; r = r + 1) begin
                    c = d - r;
                    got_C[r][c] = $signed(result_bank_a[d][r*OUTPUT_DATA_WIDTH +: OUTPUT_DATA_WIDTH]);
                end
            end
            else begin
                for (r = d-3; r < 4; r = r + 1) begin
                    c = d - r;
                    got_C[r][c] = $signed(result_bank_a[d][r*OUTPUT_DATA_WIDTH +: OUTPUT_DATA_WIDTH]);
                end
            end
        end

        // ---- Hiển thị và Đối chiếu ----
        $display("=== GOT C (from hardware) ===");
        for (i = 0; i < 4; i = i + 1)
            $display("  Row %0d: [%4d, %4d, %4d, %4d]",
                i, got_C[i][0], got_C[i][1], got_C[i][2], got_C[i][3]);
        $display("");

        $display("=== VERIFICATION ===");
        for (i = 0; i < 4; i = i + 1)
            for (j = 0; j < 4; j = j + 1) begin
                if (got_C[i][j] === exp_C[i][j]) begin
                    pass_cnt = pass_cnt + 1;
                    $display("  PASS C[%0d][%0d] = %0d", i, j, got_C[i][j]);
                end
                else begin
                    fail_cnt = fail_cnt + 1;
                    $display("  FAIL C[%0d][%0d]: expected %0d, got %0d",
                             i, j, exp_C[i][j], got_C[i][j]);
                end
            end

        $display("");
        $display("====================================");
        $display("TOTAL: %0d PASS  %0d FAIL  (of 16)", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("ALL PASS ✓");
        else
            $display("FAILURES DETECTED ✗");
        $display("====================================");

        $finish;
    end

endmodule
