`timescale 1ns/1ps

module ines_header_parser #(
    parameter [3:0] INES_DEFAULT_RAM_SHIFT = 4'd7
)(
    input  wire         clk,
    input  wire         reset,
    input  wire         start,
    input  wire [127:0] header,
    input  wire [31:0]  actual_size,

    output wire         busy,
    output wire         done,
    output wire         valid,
    output wire [3:0]   error,
    output wire         nes2,
    output wire         dirty_ines,
    output wire [11:0]  mapper_id,
    output wire [3:0]   submapper_id,
    output wire [25:0]  prg_size_bytes,
    output wire [25:0]  chr_size_bytes,
    output wire [1:0]   mirroring,
    output wire         four_screen,
    output wire         trainer,
    output wire         battery,
    output wire [3:0]   prg_ram_shift,
    output wire [3:0]   chr_ram_shift,
    output wire [1:0]   cpu_ppu_timing,
    output wire         prg_rom_exponent,
    output wire         chr_rom_exponent,
    output wire         prg_ram_exponent,
    output wire         chr_ram_exponent,
    output wire [27:0]  expected_size,
    output wire         size_trailing,
    output wire [3:0]   dbg_byte_index,
    output wire [127:0] dbg_header
);

    localparam [3:0] ERR_NONE       = 4'd0;
    localparam [3:0] ERR_MAGIC      = 4'd1;
    localparam [3:0] ERR_PRG_ZERO   = 4'd2;
    localparam [3:0] ERR_EXPONENT   = 4'd3;
    localparam [3:0] ERR_SIZE_SHORT = 4'd4;

    localparam [1:0] ST_IDLE   = 2'd0;
    localparam [1:0] ST_FETCH  = 2'd1;
    localparam [1:0] ST_DECODE = 2'd2;

    reg [1:0]   state;
    reg [3:0]   byte_index;
    reg [127:0] hdr_q;
    reg [31:0]  size_q;

    reg         valid_r;
    reg [3:0]   error_r;
    reg         nes2_r;
    reg         dirty_r;
    reg [11:0]  mapper_r;
    reg [3:0]   submapper_r;
    reg [25:0]  prg_size_r;
    reg [25:0]  chr_size_r;
    reg [1:0]   mirroring_r;
    reg         four_screen_r;
    reg         trainer_r;
    reg         battery_r;
    reg [3:0]   prg_shift_r;
    reg [3:0]   chr_shift_r;
    reg [1:0]   timing_r;
    reg         prg_exp_r;
    reg         chr_exp_r;
    reg         prg_ram_exp_r;
    reg         chr_ram_exp_r;
    reg [27:0]  expected_r;
    reg         trailing_r;

    wire [6:0] byte_offset = {byte_index, 3'b000};

    wire [7:0]  f4  = hdr_q[39:32];
    wire [7:0]  f5  = hdr_q[47:40];
    wire [7:0]  f6  = hdr_q[55:48];
    wire [7:0]  f7  = hdr_q[63:56];
    wire [7:0]  f8  = hdr_q[71:64];
    wire [7:0]  f9  = hdr_q[79:72];
    wire [7:0]  f10 = hdr_q[87:80];
    wire [7:0]  f11 = hdr_q[95:88];
    wire [7:0]  f12 = hdr_q[103:96];

    wire magic_ok = (hdr_q[7:0]   == 8'h4E) &&
                   (hdr_q[15:8]  == 8'h45) &&
                   (hdr_q[23:16] == 8'h53) &&
                   (hdr_q[31:24] == 8'h1A);
    wire tail_zero = (hdr_q[127:96] == 32'd0);

    wire nes2_d = (f7[3:2] == 2'b10);
    wire clean_ines_d = (f7[3:2] == 2'b00) && tail_zero;
    wire dirty_d = !nes2_d && !clean_ines_d;

    wire [11:0] mapper_ines   = {4'd0, f7[7:4], f6[7:4]};
    wire [11:0] mapper_nes2   = {f8[3:0], f7[7:4], f6[7:4]};
    wire [11:0] mapper_masked = {8'd0, f6[7:4]};
    wire [11:0] mapper_d = nes2_d ? mapper_nes2 :
                          dirty_d ? mapper_masked : mapper_ines;

    wire [3:0] submapper_d = nes2_d ? f8[7:4] : 4'd0;

    wire [11:0] prg_blocks = nes2_d ? {f9[3:0], f4} : {4'd0, f4};
    wire [11:0] chr_blocks = nes2_d ? {f9[7:4], f5} : {4'd0, f5};
    wire [25:0] prg_size_d = {prg_blocks, 14'd0};
    wire [25:0] chr_size_d = {1'b0, chr_blocks, 13'd0};

    wire trainer_d = f6[2];
    wire [27:0] expected_d = 28'd16 + (trainer_d ? 28'd512 : 28'd0)
                              + {2'b00, prg_size_d} + {2'b00, chr_size_d};
    wire size_short = ({4'd0, size_q} < expected_d);
    wire size_long  = ({4'd0, size_q} > expected_d);

    wire [3:0] prg_shift_d = nes2_d ? f10[3:0] : INES_DEFAULT_RAM_SHIFT;
    wire [3:0] chr_shift_d = nes2_d ? f11[3:0] : INES_DEFAULT_RAM_SHIFT;
    wire prg_exp_d = nes2_d && (f9[7:4] != 4'h0);
    wire chr_exp_d = nes2_d && (f9[3:2] != 2'b00);
    wire prg_ram_exp_d = nes2_d && (f10[7:6] != 2'b00);
    wire chr_ram_exp_d = nes2_d && (f11[7:6] != 2'b00);
    wire exponent_d = prg_exp_d | chr_exp_d | prg_ram_exp_d | chr_ram_exp_d;

    wire [1:0] timing_d = nes2_d ? f12[1:0] : 2'b00;
    wire [1:0] mirroring_d = f6[0] ? 2'b01 : 2'b00;
    wire four_screen_d = f6[3];
    wire battery_d = f6[1];

    wire [3:0] error_d = !magic_ok     ? ERR_MAGIC :
                        (prg_blocks == 12'd0) ? ERR_PRG_ZERO :
                        exponent_d    ? ERR_EXPONENT :
                        size_short    ? ERR_SIZE_SHORT : ERR_NONE;

    wire keep_d = magic_ok;

    assign busy          = (state != ST_IDLE);
    assign done          = (state == ST_DECODE);
    assign valid         = valid_r;
    assign error         = error_r;
    assign nes2          = nes2_r;
    assign dirty_ines    = dirty_r;
    assign mapper_id     = mapper_r;
    assign submapper_id  = submapper_r;
    assign prg_size_bytes = prg_size_r;
    assign chr_size_bytes = chr_size_r;
    assign mirroring     = mirroring_r;
    assign four_screen   = four_screen_r;
    assign trainer       = trainer_r;
    assign battery       = battery_r;
    assign prg_ram_shift = prg_shift_r;
    assign chr_ram_shift = chr_shift_r;
    assign cpu_ppu_timing = timing_r;
    assign prg_rom_exponent = prg_exp_r;
    assign chr_rom_exponent = chr_exp_r;
    assign prg_ram_exponent = prg_ram_exp_r;
    assign chr_ram_exponent = chr_ram_exp_r;
    assign expected_size = expected_r;
    assign size_trailing = trailing_r;
    assign dbg_byte_index = byte_index;
    assign dbg_header    = hdr_q;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state         <= ST_IDLE;
            byte_index    <= 4'd0;
            hdr_q         <= 128'd0;
            size_q        <= 32'd0;
            valid_r       <= 1'b0;
            error_r       <= ERR_NONE;
            nes2_r        <= 1'b0;
            dirty_r       <= 1'b0;
            mapper_r      <= 12'd0;
            submapper_r   <= 4'd0;
            prg_size_r    <= 26'd0;
            chr_size_r    <= 26'd0;
            mirroring_r   <= 2'd0;
            four_screen_r <= 1'b0;
            trainer_r     <= 1'b0;
            battery_r     <= 1'b0;
            prg_shift_r   <= 4'd0;
            chr_shift_r   <= 4'd0;
            timing_r      <= 2'd0;
            prg_exp_r     <= 1'b0;
            chr_exp_r     <= 1'b0;
            prg_ram_exp_r <= 1'b0;
            chr_ram_exp_r <= 1'b0;
            expected_r    <= 28'd0;
            trailing_r    <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (start) begin
                        hdr_q      <= 128'd0;
                        size_q     <= actual_size;
                        byte_index <= 4'd0;
                        state      <= ST_FETCH;
                    end
                end

                ST_FETCH: begin
                    hdr_q[byte_offset +: 8] <= header[byte_offset +: 8];
                    if (byte_index == 4'd15) begin
                        byte_index <= 4'd0;
                        state      <= ST_DECODE;
                    end else begin
                        byte_index <= byte_index + 4'd1;
                    end
                end

                ST_DECODE: begin
                    valid_r       <= (error_d == ERR_NONE);
                    error_r       <= error_d;
                    nes2_r        <= keep_d && nes2_d;
                    dirty_r       <= keep_d && dirty_d;
                    mapper_r      <= keep_d ? mapper_d : 12'd0;
                    submapper_r   <= keep_d ? submapper_d : 4'd0;
                    prg_size_r    <= keep_d ? prg_size_d : 26'd0;
                    chr_size_r    <= keep_d ? chr_size_d : 26'd0;
                    mirroring_r   <= keep_d ? mirroring_d : 2'd0;
                    four_screen_r <= keep_d && four_screen_d;
                    trainer_r     <= keep_d && trainer_d;
                    battery_r     <= keep_d && battery_d;
                    prg_shift_r   <= keep_d ? prg_shift_d : 4'd0;
                    chr_shift_r   <= keep_d ? chr_shift_d : 4'd0;
                    timing_r      <= keep_d ? timing_d : 2'd0;
                    prg_exp_r     <= keep_d && prg_exp_d;
                    chr_exp_r     <= keep_d && chr_exp_d;
                    prg_ram_exp_r <= keep_d && prg_ram_exp_d;
                    chr_ram_exp_r <= keep_d && chr_ram_exp_d;
                    expected_r    <= keep_d ? expected_d : 28'd0;
                    trailing_r    <= keep_d && size_long;
                    state         <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
