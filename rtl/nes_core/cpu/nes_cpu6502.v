`timescale 1ns/1ps

module nes_cpu6502(
    input wire clk,
    input wire reset,
    input wire ce,
    input wire bus_hold,
    input wire [7:0] bus_din,
    input wire bus_ready,
    input wire nmi_i,
    input wire irq_i,
    output reg bus_req,
    output wire bus_fire,
    output wire [31:0] cpu_cycle,
    output wire [3:0] cpu_cycle_phase,
    output reg [15:0] bus_addr,
    output reg bus_we,
    output reg [7:0] bus_dout,
    output wire [15:0] dbg_pc,
    output wire [7:0] dbg_a,
    output wire [7:0] dbg_x,
    output wire [7:0] dbg_y,
    output wire [7:0] dbg_sp,
    output wire [7:0] dbg_p,
    output wire [7:0] dbg_opcode,
    output wire [6:0] dbg_state,
    output wire dbg_nmi_pending,
    output wire dbg_irq_pending,
    output wire dbg_illegal
);

localparam [6:0] ST_RESET_0 = 7'd0;
localparam [6:0] ST_RESET_1 = 7'd1;
localparam [6:0] ST_RESET_2 = 7'd2;
localparam [6:0] ST_RESET_3 = 7'd3;
localparam [6:0] ST_RESET_4 = 7'd4;
localparam [6:0] ST_RESET_LO = 7'd5;
localparam [6:0] ST_RESET_HI = 7'd6;
localparam [6:0] ST_FETCH = 7'd7;
localparam [6:0] ST_IMM = 7'd8;
localparam [6:0] ST_IMP = 7'd9;
localparam [6:0] ST_ZP_ADDR = 7'd10;
localparam [6:0] ST_ZPI_ADDR = 7'd11;
localparam [6:0] ST_ZPI_DUMMY = 7'd12;
localparam [6:0] ST_DATA = 7'd13;
localparam [6:0] ST_ABS_LO = 7'd14;
localparam [6:0] ST_ABS_HI = 7'd15;
localparam [6:0] ST_ABI_DUMMY = 7'd16;
localparam [6:0] ST_IZX_ADDR = 7'd17;
localparam [6:0] ST_IZX_DUMMY = 7'd18;
localparam [6:0] ST_IZX_LO = 7'd19;
localparam [6:0] ST_IZX_HI = 7'd20;
localparam [6:0] ST_IZY_ADDR = 7'd21;
localparam [6:0] ST_IZY_LO = 7'd22;
localparam [6:0] ST_IZY_HI = 7'd23;
localparam [6:0] ST_IZY_DUMMY = 7'd24;
localparam [6:0] ST_BRANCH_OP = 7'd25;
localparam [6:0] ST_BRANCH_DUMMY = 7'd26;
localparam [6:0] ST_BRANCH_CROSS = 7'd27;
localparam [6:0] ST_RMW_OLD_WRITE = 7'd28;
localparam [6:0] ST_RMW_WRITE = 7'd29;
localparam [6:0] ST_JMP_IND_LO = 7'd30;
localparam [6:0] ST_JMP_IND_HI = 7'd31;
localparam [6:0] ST_JSR_LO = 7'd32;
localparam [6:0] ST_JSR_STACK = 7'd33;
localparam [6:0] ST_JSR_PUSH_HI = 7'd34;
localparam [6:0] ST_JSR_PUSH_LO = 7'd35;
localparam [6:0] ST_JSR_HI = 7'd36;
localparam [6:0] ST_RTS_DUMMY = 7'd37;
localparam [6:0] ST_RTS_STACK = 7'd38;
localparam [6:0] ST_RTS_LO = 7'd39;
localparam [6:0] ST_RTS_HI = 7'd40;
localparam [6:0] ST_RTS_INC = 7'd41;
localparam [6:0] ST_RTI_DUMMY = 7'd42;
localparam [6:0] ST_RTI_STACK = 7'd43;
localparam [6:0] ST_RTI_P = 7'd44;
localparam [6:0] ST_RTI_LO = 7'd45;
localparam [6:0] ST_RTI_HI = 7'd46;
localparam [6:0] ST_PUSH_DUMMY = 7'd47;
localparam [6:0] ST_PUSH = 7'd48;
localparam [6:0] ST_PULL_DUMMY = 7'd49;
localparam [6:0] ST_PULL_STACK = 7'd50;
localparam [6:0] ST_PULL = 7'd51;
localparam [6:0] ST_BRK_DUMMY = 7'd52;
localparam [6:0] ST_INT_DUMMY2 = 7'd54;
localparam [6:0] ST_INT_PUSH_HI = 7'd55;
localparam [6:0] ST_INT_PUSH_LO = 7'd56;
localparam [6:0] ST_INT_PUSH_P = 7'd57;
localparam [6:0] ST_INT_VEC_LO = 7'd58;
localparam [6:0] ST_INT_VEC_HI = 7'd59;
localparam [6:0] ST_TRAP = 7'd60;

localparam [5:0] C_TRAP = 6'd0;
localparam [5:0] C_LDA = 6'd1;
localparam [5:0] C_LDX = 6'd2;
localparam [5:0] C_LDY = 6'd3;
localparam [5:0] C_STA = 6'd4;
localparam [5:0] C_STX = 6'd5;
localparam [5:0] C_STY = 6'd6;
localparam [5:0] C_ADC = 6'd7;
localparam [5:0] C_SBC = 6'd8;
localparam [5:0] C_AND = 6'd9;
localparam [5:0] C_ORA = 6'd10;
localparam [5:0] C_EOR = 6'd11;
localparam [5:0] C_CMP = 6'd12;
localparam [5:0] C_CPX = 6'd13;
localparam [5:0] C_CPY = 6'd14;
localparam [5:0] C_BIT = 6'd15;
localparam [5:0] C_ASL = 6'd16;
localparam [5:0] C_LSR = 6'd17;
localparam [5:0] C_ROL = 6'd18;
localparam [5:0] C_ROR = 6'd19;
localparam [5:0] C_INC = 6'd20;
localparam [5:0] C_DEC = 6'd21;
localparam [5:0] C_TAX = 6'd22;
localparam [5:0] C_TAY = 6'd23;
localparam [5:0] C_TXA = 6'd24;
localparam [5:0] C_TYA = 6'd25;
localparam [5:0] C_TSX = 6'd26;
localparam [5:0] C_TXS = 6'd27;
localparam [5:0] C_INX = 6'd28;
localparam [5:0] C_INY = 6'd29;
localparam [5:0] C_DEX = 6'd30;
localparam [5:0] C_DEY = 6'd31;
localparam [5:0] C_CLC = 6'd32;
localparam [5:0] C_SEC = 6'd33;
localparam [5:0] C_CLI = 6'd34;
localparam [5:0] C_SEI = 6'd35;
localparam [5:0] C_CLD = 6'd36;
localparam [5:0] C_SED = 6'd37;
localparam [5:0] C_CLV = 6'd38;
localparam [5:0] C_BRANCH = 6'd39;
localparam [5:0] C_JMP = 6'd40;
localparam [5:0] C_JSR = 6'd41;
localparam [5:0] C_RTS = 6'd42;
localparam [5:0] C_RTI = 6'd43;
localparam [5:0] C_BRK = 6'd44;
localparam [5:0] C_PUSH_A = 6'd45;
localparam [5:0] C_PUSH_P = 6'd46;
localparam [5:0] C_PULL_A = 6'd47;
localparam [5:0] C_PULL_P = 6'd48;
localparam [5:0] C_NOP = 6'd49;

localparam [3:0] AM_IMP = 4'd0;
localparam [3:0] AM_ACC = 4'd1;
localparam [3:0] AM_IMM = 4'd2;
localparam [3:0] AM_ZP = 4'd3;
localparam [3:0] AM_ZPX = 4'd4;
localparam [3:0] AM_ZPY = 4'd5;
localparam [3:0] AM_ABS = 4'd6;
localparam [3:0] AM_ABX = 4'd7;
localparam [3:0] AM_ABY = 4'd8;
localparam [3:0] AM_IND = 4'd9;
localparam [3:0] AM_IZX = 4'd10;
localparam [3:0] AM_IZY = 4'd11;
localparam [3:0] AM_REL = 4'd12;

localparam [1:0] ACCESS_NONE = 2'd0;
localparam [1:0] ACCESS_READ = 2'd1;
localparam [1:0] ACCESS_WRITE = 2'd2;
localparam [1:0] ACCESS_RMW = 2'd3;

localparam [1:0] INT_NONE = 2'd0;
localparam [1:0] INT_NMI = 2'd1;
localparam [1:0] INT_IRQ = 2'd2;
localparam [1:0] INT_BRK = 2'd3;

reg [6:0] state_reg;
reg [15:0] pc_reg;
reg [15:0] addr_reg;
reg [15:0] operand_reg;
reg [15:0] ptr_reg;
reg [15:0] vector_reg;
reg [15:0] int_pc_push_reg;
reg [15:0] branch_target_reg;
reg [15:0] rmw_addr_reg;
reg [7:0] a_reg;
reg [7:0] x_reg;
reg [7:0] y_reg;
reg [7:0] sp_reg;
reg [7:0] p_reg;
reg [7:0] opcode_reg;
reg [7:0] rmw_data_reg;
reg [5:0] class_reg;
reg [3:0] mode_reg;
reg [1:0] access_reg;
reg [1:0] int_kind_reg;
reg int_push_b_reg;
reg nmi_pending_reg;
reg nmi_sync_reg;
reg illegal_reg;
reg [31:0] cpu_cycle_reg;
reg [3:0] cycle_phase_reg;
reg [5:0] fetched_class;
reg [3:0] fetched_mode;
reg [1:0] fetched_access;
reg [7:0] rmw_result;

wire cpu_active;
wire nmi_rise;
wire [7:0] selected_index;
wire [15:0] abs_base_from_bus;
wire [15:0] abs_indexed_from_bus;
wire [15:0] abs_wrong_from_bus;
wire [15:0] abs_indexed_addr;
wire [15:0] izy_base_from_bus;
wire [15:0] izy_fixed_from_bus;
wire [15:0] izy_wrong_from_bus;
wire [15:0] izy_fixed_addr;
wire [15:0] interrupt_vector;
wire [7:0] interrupt_push_data;
wire [7:0] store_data;
wire [7:0] push_data;

assign cpu_active = ce && !bus_hold && !reset;
assign nmi_rise = nmi_i && !nmi_sync_reg;
assign selected_index = ((mode_reg == AM_ZPY) || (mode_reg == AM_ABY)) ? y_reg : x_reg;
assign abs_base_from_bus = {bus_din, operand_reg[7:0]};
assign abs_indexed_from_bus = abs_base_from_bus + {8'h00, selected_index};
assign abs_wrong_from_bus = {bus_din, operand_reg[7:0] + selected_index};
assign abs_indexed_addr = operand_reg + {8'h00, selected_index};
assign izy_base_from_bus = {bus_din, operand_reg[7:0]};
assign izy_fixed_from_bus = izy_base_from_bus + {8'h00, y_reg};
assign izy_wrong_from_bus = {bus_din, operand_reg[7:0] + y_reg};
assign izy_fixed_addr = operand_reg + {8'h00, y_reg};
assign interrupt_vector = (int_kind_reg == INT_NMI) ? 16'hFFFA : 16'hFFFE;
assign interrupt_push_data = (p_reg | 8'h20) | (int_push_b_reg ? 8'h10 : 8'h00);
assign store_data = (class_reg == C_STA) ? a_reg : ((class_reg == C_STX) ? x_reg : y_reg);
assign push_data = (class_reg == C_PUSH_A) ? a_reg : (p_reg | 8'h30);
assign bus_fire = bus_req && bus_ready;
assign cpu_cycle = cpu_cycle_reg;
assign cpu_cycle_phase = cycle_phase_reg;
assign dbg_pc = pc_reg;
assign dbg_a = a_reg;
assign dbg_x = x_reg;
assign dbg_y = y_reg;
assign dbg_sp = sp_reg;
assign dbg_p = p_reg;
assign dbg_opcode = opcode_reg;
assign dbg_state = state_reg;
assign dbg_nmi_pending = nmi_pending_reg;
assign dbg_irq_pending = irq_i;
assign dbg_illegal = illegal_reg;

function [5:0] decode_class;
    input [7:0] op;
    begin
        case (op)
            8'h01, 8'h05, 8'h09, 8'h0D, 8'h11, 8'h15, 8'h19, 8'h1D: decode_class = C_ORA;
            8'h21, 8'h25, 8'h29, 8'h2D, 8'h31, 8'h35, 8'h39, 8'h3D: decode_class = C_AND;
            8'h41, 8'h45, 8'h49, 8'h4D, 8'h51, 8'h55, 8'h59, 8'h5D: decode_class = C_EOR;
            8'h61, 8'h65, 8'h69, 8'h6D, 8'h71, 8'h75, 8'h79, 8'h7D: decode_class = C_ADC;
            8'h81, 8'h85, 8'h8D, 8'h91, 8'h95, 8'h99, 8'h9D: decode_class = C_STA;
            8'hA1, 8'hA5, 8'hA9, 8'hAD, 8'hB1, 8'hB5, 8'hB9, 8'hBD: decode_class = C_LDA;
            8'hC1, 8'hC5, 8'hC9, 8'hCD, 8'hD1, 8'hD5, 8'hD9, 8'hDD: decode_class = C_CMP;
            8'hE0, 8'hE4, 8'hEC: decode_class = C_CPX;
            8'hC0, 8'hC4, 8'hCC: decode_class = C_CPY;
            8'hE1, 8'hE5, 8'hE9, 8'hED, 8'hF1, 8'hF5, 8'hF9, 8'hFD: decode_class = C_SBC;
            8'hA2, 8'hA6, 8'hAE, 8'hB6, 8'hBE: decode_class = C_LDX;
            8'hA0, 8'hA4, 8'hAC, 8'hB4, 8'hBC: decode_class = C_LDY;
            8'h86, 8'h96, 8'h8E: decode_class = C_STX;
            8'h84, 8'h94, 8'h8C: decode_class = C_STY;
            8'h24, 8'h2C: decode_class = C_BIT;
            8'h0A, 8'h06, 8'h16, 8'h0E, 8'h1E: decode_class = C_ASL;
            8'h2A, 8'h26, 8'h36, 8'h2E, 8'h3E: decode_class = C_ROL;
            8'h4A, 8'h46, 8'h56, 8'h4E, 8'h5E: decode_class = C_LSR;
            8'h6A, 8'h66, 8'h76, 8'h6E, 8'h7E: decode_class = C_ROR;
            8'hC6, 8'hD6, 8'hCE, 8'hDE: decode_class = C_DEC;
            8'hE6, 8'hF6, 8'hEE, 8'hFE: decode_class = C_INC;
            8'hAA: decode_class = C_TAX;
            8'hA8: decode_class = C_TAY;
            8'h8A: decode_class = C_TXA;
            8'h98: decode_class = C_TYA;
            8'hBA: decode_class = C_TSX;
            8'h9A: decode_class = C_TXS;
            8'hE8: decode_class = C_INX;
            8'hC8: decode_class = C_INY;
            8'hCA: decode_class = C_DEX;
            8'h88: decode_class = C_DEY;
            8'h18: decode_class = C_CLC;
            8'h38: decode_class = C_SEC;
            8'h58: decode_class = C_CLI;
            8'h78: decode_class = C_SEI;
            8'hD8: decode_class = C_CLD;
            8'hF8: decode_class = C_SED;
            8'hB8: decode_class = C_CLV;
            8'h10, 8'h30, 8'h50, 8'h70, 8'h90, 8'hB0, 8'hD0, 8'hF0: decode_class = C_BRANCH;
            8'h4C, 8'h6C: decode_class = C_JMP;
            8'h20: decode_class = C_JSR;
            8'h60: decode_class = C_RTS;
            8'h40: decode_class = C_RTI;
            8'h00: decode_class = C_BRK;
            8'h08: decode_class = C_PUSH_P;
            8'h48: decode_class = C_PUSH_A;
            8'h68: decode_class = C_PULL_A;
            8'h28: decode_class = C_PULL_P;
            8'hEA: decode_class = C_NOP;
            default: decode_class = C_TRAP;
        endcase
    end
endfunction

function [3:0] decode_mode;
    input [7:0] op;
    begin
        case (op)
            8'h09, 8'h29, 8'h49, 8'h69, 8'hA9, 8'hC9, 8'hE9, 8'hA2, 8'hA0, 8'hE0, 8'hC0: decode_mode = AM_IMM;
            8'h01, 8'h21, 8'h41, 8'h61, 8'h81, 8'hA1, 8'hC1, 8'hE1: decode_mode = AM_IZX;
            8'h11, 8'h31, 8'h51, 8'h71, 8'h91, 8'hB1, 8'hD1, 8'hF1: decode_mode = AM_IZY;
            8'h05, 8'h25, 8'h45, 8'h65, 8'h85, 8'hA5, 8'hC5, 8'hE5, 8'h24, 8'h06, 8'h26, 8'h46, 8'h66, 8'h86, 8'hA6, 8'hC6, 8'hE6, 8'h84, 8'hA4, 8'hE4, 8'hC4: decode_mode = AM_ZP;
            8'h15, 8'h35, 8'h55, 8'h75, 8'h95, 8'hB5, 8'hD5, 8'hF5, 8'h16, 8'h36, 8'h56, 8'h76, 8'hD6, 8'hF6, 8'h94, 8'hB4: decode_mode = AM_ZPX;
            8'hB6, 8'h96: decode_mode = AM_ZPY;
            8'h0D, 8'h2D, 8'h4D, 8'h6D, 8'h8D, 8'hAD, 8'hCD, 8'hED, 8'h2C, 8'h0E, 8'h2E, 8'h4E, 8'h6E, 8'hCE, 8'hEE, 8'h8E, 8'hAE, 8'hAC, 8'h8C, 8'h4C, 8'h20, 8'hEC, 8'hCC: decode_mode = AM_ABS;
            8'h1D, 8'h3D, 8'h5D, 8'h7D, 8'h9D, 8'hBD, 8'hDD, 8'hFD, 8'h1E, 8'h3E, 8'h5E, 8'h7E, 8'hDE, 8'hFE, 8'hBC: decode_mode = AM_ABX;
            8'h19, 8'h39, 8'h59, 8'h79, 8'h99, 8'hB9, 8'hBE, 8'hD9, 8'hF9: decode_mode = AM_ABY;
            8'h6C: decode_mode = AM_IND;
            8'h10, 8'h30, 8'h50, 8'h70, 8'h90, 8'hB0, 8'hD0, 8'hF0: decode_mode = AM_REL;
            8'h0A, 8'h2A, 8'h4A, 8'h6A: decode_mode = AM_ACC;
            default: decode_mode = AM_IMP;
        endcase
    end
endfunction

function [1:0] decode_access;
    input [7:0] op;
    begin
        case (decode_class(op))
            C_LDA, C_LDX, C_LDY, C_ADC, C_SBC, C_AND, C_ORA, C_EOR, C_CMP, C_CPX, C_CPY, C_BIT: decode_access = ACCESS_READ;
            C_STA, C_STX, C_STY: decode_access = ACCESS_WRITE;
            C_ASL, C_LSR, C_ROL, C_ROR, C_INC, C_DEC: begin
                if (decode_mode(op) == AM_ACC)
                    decode_access = ACCESS_NONE;
                else
                    decode_access = ACCESS_RMW;
            end
            default: decode_access = ACCESS_NONE;
        endcase
    end
endfunction

function [0:0] branch_take;
    input [7:0] op;
    input [7:0] flags;
    begin
        case (op)
            8'h10: branch_take = !flags[7];
            8'h30: branch_take = flags[7];
            8'h50: branch_take = !flags[6];
            8'h70: branch_take = flags[6];
            8'h90: branch_take = !flags[0];
            8'hB0: branch_take = flags[0];
            8'hD0: branch_take = !flags[1];
            8'hF0: branch_take = flags[1];
            default: branch_take = 1'b0;
        endcase
    end
endfunction

function [7:0] add_zp_index;
    input [7:0] base;
    input [7:0] index;
    begin
        add_zp_index = base + index;
    end
endfunction

function [15:0] add_signed_offset;
    input [15:0] base;
    input [7:0] offset;
    begin
        add_signed_offset = base + {{8{offset[7]}}, offset};
    end
endfunction

always @* begin
    fetched_class = decode_class(bus_din);
    fetched_mode = decode_mode(bus_din);
    fetched_access = decode_access(bus_din);
end

always @* begin
    rmw_result = rmw_data_reg;
    case (class_reg)
        C_ASL: rmw_result = {rmw_data_reg[6:0], 1'b0};
        C_LSR: rmw_result = {1'b0, rmw_data_reg[7:1]};
        C_ROL: rmw_result = {rmw_data_reg[6:0], p_reg[0]};
        C_ROR: rmw_result = {p_reg[0], rmw_data_reg[7:1]};
        C_INC: rmw_result = rmw_data_reg + 8'd1;
        C_DEC: rmw_result = rmw_data_reg - 8'd1;
        default: rmw_result = rmw_data_reg;
    endcase
end

task do_read_value;
    input [7:0] value;
    reg [8:0] sum;
    reg [8:0] difference;
    begin
        case (class_reg)
            C_LDA: begin
                a_reg <= value;
                p_reg[1] <= (value == 8'h00);
                p_reg[7] <= value[7];
            end
            C_LDX: begin
                x_reg <= value;
                p_reg[1] <= (value == 8'h00);
                p_reg[7] <= value[7];
            end
            C_LDY: begin
                y_reg <= value;
                p_reg[1] <= (value == 8'h00);
                p_reg[7] <= value[7];
            end
            C_AND: begin
                a_reg <= a_reg & value;
                p_reg[1] <= ((a_reg & value) == 8'h00);
                p_reg[7] <= (a_reg & value) >> 7;
            end
            C_ORA: begin
                a_reg <= a_reg | value;
                p_reg[1] <= ((a_reg | value) == 8'h00);
                p_reg[7] <= (a_reg | value) >> 7;
            end
            C_EOR: begin
                a_reg <= a_reg ^ value;
                p_reg[1] <= ((a_reg ^ value) == 8'h00);
                p_reg[7] <= (a_reg ^ value) >> 7;
            end
            C_ADC: begin
                sum = {1'b0, a_reg} + {1'b0, value} + {8'h00, p_reg[0]};
                a_reg <= sum[7:0];
                p_reg[0] <= sum[8];
                p_reg[1] <= (sum[7:0] == 8'h00);
                p_reg[7] <= sum[7];
                p_reg[6] <= ((a_reg[7] ^ sum[7]) & (value[7] ^ sum[7]));
            end
            C_SBC: begin
                sum = {1'b0, a_reg} + {1'b0, ~value} + {8'h00, p_reg[0]};
                a_reg <= sum[7:0];
                p_reg[0] <= sum[8];
                p_reg[1] <= (sum[7:0] == 8'h00);
                p_reg[7] <= sum[7];
                p_reg[6] <= ((a_reg[7] ^ sum[7]) & ((~value[7]) ^ sum[7]));
            end
            C_CMP: begin
                difference = {1'b0, a_reg} - {1'b0, value};
                p_reg[0] <= !difference[8];
                p_reg[1] <= (difference[7:0] == 8'h00);
                p_reg[7] <= difference[7];
            end
            C_CPX: begin
                difference = {1'b0, x_reg} - {1'b0, value};
                p_reg[0] <= !difference[8];
                p_reg[1] <= (difference[7:0] == 8'h00);
                p_reg[7] <= difference[7];
            end
            C_CPY: begin
                difference = {1'b0, y_reg} - {1'b0, value};
                p_reg[0] <= !difference[8];
                p_reg[1] <= (difference[7:0] == 8'h00);
                p_reg[7] <= difference[7];
            end
            C_BIT: begin
                p_reg[1] <= ((a_reg & value) == 8'h00);
                p_reg[6] <= value[6];
                p_reg[7] <= value[7];
            end
            default: begin
            end
        endcase
    end
endtask

task do_implicit_value;
    reg [7:0] result;
    begin
        case (class_reg)
            C_TAX: begin
                x_reg <= a_reg;
                p_reg[1] <= (a_reg == 8'h00);
                p_reg[7] <= a_reg[7];
            end
            C_TAY: begin
                y_reg <= a_reg;
                p_reg[1] <= (a_reg == 8'h00);
                p_reg[7] <= a_reg[7];
            end
            C_TXA: begin
                a_reg <= x_reg;
                p_reg[1] <= (x_reg == 8'h00);
                p_reg[7] <= x_reg[7];
            end
            C_TYA: begin
                a_reg <= y_reg;
                p_reg[1] <= (y_reg == 8'h00);
                p_reg[7] <= y_reg[7];
            end
            C_TSX: begin
                x_reg <= sp_reg;
                p_reg[1] <= (sp_reg == 8'h00);
                p_reg[7] <= sp_reg[7];
            end
            C_TXS: begin
                sp_reg <= x_reg;
            end
            C_INX: begin
                x_reg <= x_reg + 8'd1;
                p_reg[1] <= ((x_reg + 8'd1) == 8'h00);
                p_reg[7] <= (x_reg + 8'd1) >> 7;
            end
            C_INY: begin
                y_reg <= y_reg + 8'd1;
                p_reg[1] <= ((y_reg + 8'd1) == 8'h00);
                p_reg[7] <= (y_reg + 8'd1) >> 7;
            end
            C_DEX: begin
                x_reg <= x_reg - 8'd1;
                p_reg[1] <= ((x_reg - 8'd1) == 8'h00);
                p_reg[7] <= (x_reg - 8'd1) >> 7;
            end
            C_DEY: begin
                y_reg <= y_reg - 8'd1;
                p_reg[1] <= ((y_reg - 8'd1) == 8'h00);
                p_reg[7] <= (y_reg - 8'd1) >> 7;
            end
            C_ASL: begin
                result = {a_reg[6:0], 1'b0};
                a_reg <= result;
                p_reg[0] <= a_reg[7];
                p_reg[1] <= (result == 8'h00);
                p_reg[7] <= result[7];
            end
            C_LSR: begin
                result = {1'b0, a_reg[7:1]};
                a_reg <= result;
                p_reg[0] <= a_reg[0];
                p_reg[1] <= (result == 8'h00);
                p_reg[7] <= result[7];
            end
            C_ROL: begin
                result = {a_reg[6:0], p_reg[0]};
                a_reg <= result;
                p_reg[0] <= a_reg[7];
                p_reg[1] <= (result == 8'h00);
                p_reg[7] <= result[7];
            end
            C_ROR: begin
                result = {p_reg[0], a_reg[7:1]};
                a_reg <= result;
                p_reg[0] <= a_reg[0];
                p_reg[1] <= (result == 8'h00);
                p_reg[7] <= result[7];
            end
            C_CLC: p_reg[0] <= 1'b0;
            C_SEC: p_reg[0] <= 1'b1;
            C_CLI: p_reg[2] <= 1'b0;
            C_SEI: p_reg[2] <= 1'b1;
            C_CLD: p_reg[3] <= 1'b0;
            C_SED: p_reg[3] <= 1'b1;
            C_CLV: p_reg[6] <= 1'b0;
            C_NOP: begin
            end
            default: begin
            end
        endcase
    end
endtask

task do_rmw_value;
    begin
        case (class_reg)
            C_ASL: begin
                p_reg[0] <= rmw_data_reg[7];
                p_reg[1] <= (rmw_result == 8'h00);
                p_reg[7] <= rmw_result[7];
            end
            C_LSR: begin
                p_reg[0] <= rmw_data_reg[0];
                p_reg[1] <= (rmw_result == 8'h00);
                p_reg[7] <= rmw_result[7];
            end
            C_ROL: begin
                p_reg[0] <= rmw_data_reg[7];
                p_reg[1] <= (rmw_result == 8'h00);
                p_reg[7] <= rmw_result[7];
            end
            C_ROR: begin
                p_reg[0] <= rmw_data_reg[0];
                p_reg[1] <= (rmw_result == 8'h00);
                p_reg[7] <= rmw_result[7];
            end
            C_INC: begin
                p_reg[1] <= (rmw_result == 8'h00);
                p_reg[7] <= rmw_result[7];
            end
            C_DEC: begin
                p_reg[1] <= (rmw_result == 8'h00);
                p_reg[7] <= rmw_result[7];
            end
            default: begin
            end
        endcase
    end
endtask

always @* begin
    bus_req = 1'b0;
    bus_addr = pc_reg;
    bus_we = 1'b0;
    bus_dout = 8'h00;
    case (state_reg)
        ST_RESET_0, ST_RESET_1, ST_RESET_2, ST_RESET_3, ST_RESET_4: begin
            bus_req = 1'b1;
            bus_addr = 16'h0000;
        end
        ST_RESET_LO: begin
            bus_req = 1'b1;
            bus_addr = 16'hFFFC;
        end
        ST_RESET_HI: begin
            bus_req = 1'b1;
            bus_addr = 16'hFFFD;
        end
        ST_FETCH, ST_IMM, ST_IMP, ST_ZP_ADDR, ST_ZPI_ADDR, ST_ABS_LO, ST_ABS_HI,
        ST_IZX_ADDR, ST_IZY_ADDR, ST_BRANCH_OP: begin
            bus_req = 1'b1;
            bus_addr = pc_reg;
        end
        ST_IZY_LO: begin
            bus_req = 1'b1;
            bus_addr = ptr_reg;
        end
        ST_IZY_HI: begin
            bus_req = 1'b1;
            bus_addr = {8'h00, ptr_reg[7:0] + 8'd1};
        end
        ST_ZPI_DUMMY, ST_IZX_DUMMY: begin
            bus_req = 1'b1;
            bus_addr = {8'h00, operand_reg[7:0]};
        end
        ST_DATA: begin
            bus_req = 1'b1;
            bus_addr = addr_reg;
            if (access_reg == ACCESS_WRITE) begin
                bus_we = 1'b1;
                bus_dout = store_data;
            end
        end
        ST_ABI_DUMMY, ST_IZY_DUMMY: begin
            bus_req = 1'b1;
            bus_addr = addr_reg;
        end
        ST_IZX_LO: begin
            bus_req = 1'b1;
            bus_addr = ptr_reg;
        end
        ST_IZX_HI: begin
            bus_req = 1'b1;
            bus_addr = {8'h00, ptr_reg[7:0] + 8'd1};
        end
        ST_BRANCH_DUMMY: begin
            bus_req = 1'b1;
            bus_addr = pc_reg;
        end
        ST_BRANCH_CROSS: begin
            bus_req = 1'b1;
            bus_addr = {pc_reg[15:8], branch_target_reg[7:0]};
        end
        ST_RMW_OLD_WRITE: begin
            bus_req = 1'b1;
            bus_addr = rmw_addr_reg;
            bus_we = 1'b1;
            bus_dout = rmw_data_reg;
        end
        ST_RMW_WRITE: begin
            bus_req = 1'b1;
            bus_addr = rmw_addr_reg;
            bus_we = 1'b1;
            bus_dout = rmw_result;
        end
        ST_JMP_IND_LO: begin
            bus_req = 1'b1;
            bus_addr = operand_reg;
        end
        ST_JMP_IND_HI: begin
            bus_req = 1'b1;
            bus_addr = {operand_reg[15:8], operand_reg[7:0] + 8'd1};
        end
        ST_JSR_LO, ST_JSR_HI: begin
            bus_req = 1'b1;
            bus_addr = pc_reg;
        end
        ST_JSR_STACK: begin
            bus_req = 1'b1;
            bus_addr = {8'h01, sp_reg};
        end
        ST_JSR_PUSH_HI, ST_JSR_PUSH_LO: begin
            bus_req = 1'b1;
            bus_addr = {8'h01, sp_reg - 8'd1};
            if (state_reg == ST_JSR_PUSH_HI) begin
                bus_we = 1'b1;
                bus_dout = pc_reg[15:8];
            end else if (state_reg == ST_JSR_PUSH_LO) begin
                bus_we = 1'b1;
                bus_dout = pc_reg[7:0];
            end
        end
        ST_RTS_DUMMY, ST_RTI_DUMMY, ST_RTS_INC: begin
            bus_req = 1'b1;
            bus_addr = pc_reg;
        end
        ST_RTS_STACK, ST_RTI_STACK, ST_RTS_LO, ST_RTS_HI, ST_RTI_P,
        ST_RTI_LO, ST_RTI_HI, ST_PULL_STACK, ST_PULL: begin
            bus_req = 1'b1;
            bus_addr = {8'h01, sp_reg};
        end
        ST_PUSH_DUMMY, ST_PULL_DUMMY: begin
            bus_req = 1'b1;
            bus_addr = pc_reg;
        end
        ST_PUSH: begin
            bus_req = 1'b1;
            bus_addr = {8'h01, sp_reg - 8'd1};
            bus_we = 1'b1;
            bus_dout = push_data;
        end
        ST_BRK_DUMMY, ST_INT_DUMMY2: begin
            bus_req = 1'b1;
            bus_addr = pc_reg;
        end
        ST_INT_PUSH_HI, ST_INT_PUSH_LO, ST_INT_PUSH_P: begin
            bus_req = 1'b1;
            bus_addr = {8'h01, sp_reg - 8'd1};
            bus_we = 1'b1;
            if (state_reg == ST_INT_PUSH_HI)
                bus_dout = int_pc_push_reg[15:8];
            else if (state_reg == ST_INT_PUSH_LO)
                bus_dout = int_pc_push_reg[7:0];
            else
                bus_dout = interrupt_push_data;
        end
        ST_INT_VEC_LO: begin
            bus_req = 1'b1;
            bus_addr = interrupt_vector;
        end
        ST_INT_VEC_HI: begin
            bus_req = 1'b1;
            bus_addr = interrupt_vector + 16'd1;
        end
        default: begin
            bus_req = 1'b0;
        end
    endcase
    if (!cpu_active)
        bus_req = 1'b0;
end

always @(posedge clk or posedge reset) begin
    if (reset) begin
        state_reg <= ST_RESET_0;
        pc_reg <= 16'h0000;
        addr_reg <= 16'h0000;
        operand_reg <= 16'h0000;
        ptr_reg <= 16'h0000;
        vector_reg <= 16'h0000;
        int_pc_push_reg <= 16'h0000;
        branch_target_reg <= 16'h0000;
        rmw_addr_reg <= 16'h0000;
        a_reg <= 8'h00;
        x_reg <= 8'h00;
        y_reg <= 8'h00;
        sp_reg <= 8'hFD;
        p_reg <= 8'h24;
        opcode_reg <= 8'h00;
        rmw_data_reg <= 8'h00;
        class_reg <= C_TRAP;
        mode_reg <= AM_IMP;
        access_reg <= ACCESS_NONE;
        int_kind_reg <= INT_NONE;
        int_push_b_reg <= 1'b0;
        nmi_pending_reg <= 1'b0;
        nmi_sync_reg <= 1'b0;
        illegal_reg <= 1'b0;
        cpu_cycle_reg <= 32'd0;
        cycle_phase_reg <= 4'd0;
    end else begin
        nmi_sync_reg <= nmi_i;
        if (nmi_rise)
            nmi_pending_reg <= 1'b1;
        if (bus_fire) begin
            cpu_cycle_reg <= cpu_cycle_reg + 32'd1;
            if (cycle_phase_reg == 4'd7)
                cycle_phase_reg <= 4'd0;
            else
                cycle_phase_reg <= cycle_phase_reg + 4'd1;
            case (state_reg)
                ST_RESET_0: state_reg <= ST_RESET_1;
                ST_RESET_1: state_reg <= ST_RESET_2;
                ST_RESET_2: state_reg <= ST_RESET_3;
                ST_RESET_3: state_reg <= ST_RESET_4;
                ST_RESET_4: state_reg <= ST_RESET_LO;
                ST_RESET_LO: begin
                    vector_reg[7:0] <= bus_din;
                    state_reg <= ST_RESET_HI;
                end
                ST_RESET_HI: begin
                    pc_reg <= {bus_din, vector_reg[7:0]};
                    sp_reg <= 8'hFD;
                    p_reg <= 8'h24;
                    state_reg <= ST_FETCH;
                end
                ST_FETCH: begin
                    opcode_reg <= bus_din;
                    class_reg <= fetched_class;
                    mode_reg <= fetched_mode;
                    access_reg <= fetched_access;
                    operand_reg <= 16'h0000;
                    addr_reg <= 16'h0000;
                    if (nmi_pending_reg) begin
                        illegal_reg <= 1'b0;
                        int_kind_reg <= INT_NMI;
                        int_pc_push_reg <= pc_reg;
                        int_push_b_reg <= 1'b0;
                        if (!nmi_rise)
                            nmi_pending_reg <= 1'b0;
                        state_reg <= ST_INT_DUMMY2;
                    end else if (irq_i && !p_reg[2]) begin
                        illegal_reg <= 1'b0;
                        int_kind_reg <= INT_IRQ;
                        int_pc_push_reg <= pc_reg;
                        int_push_b_reg <= 1'b0;
                        state_reg <= ST_INT_DUMMY2;
                    end else if (fetched_class == C_TRAP) begin
                        illegal_reg <= 1'b1;
                        state_reg <= ST_TRAP;
                    end else if (fetched_class == C_BRK) begin
                        illegal_reg <= 1'b0;
                        pc_reg <= pc_reg + 16'd1;
                        int_kind_reg <= INT_BRK;
                        int_pc_push_reg <= pc_reg + 16'd1;
                        int_push_b_reg <= 1'b1;
                        state_reg <= ST_BRK_DUMMY;
                    end else begin
                        illegal_reg <= 1'b0;
                        pc_reg <= pc_reg + 16'd1;
                        case (fetched_class)
                            C_JSR: state_reg <= ST_JSR_LO;
                            C_JMP: state_reg <= ST_ABS_LO;
                            C_RTS: state_reg <= ST_RTS_DUMMY;
                            C_RTI: state_reg <= ST_RTI_DUMMY;
                            C_BRANCH: state_reg <= ST_BRANCH_OP;
                            C_PUSH_A, C_PUSH_P: state_reg <= ST_PUSH_DUMMY;
                            C_PULL_A, C_PULL_P: state_reg <= ST_PULL_DUMMY;
                            default: begin
                                case (fetched_mode)
                                    AM_IMM: state_reg <= ST_IMM;
                                    AM_ACC, AM_IMP: state_reg <= ST_IMP;
                                    AM_ZP: state_reg <= ST_ZP_ADDR;
                                    AM_ZPX, AM_ZPY: state_reg <= ST_ZPI_ADDR;
                                    AM_ABS, AM_ABX, AM_ABY: state_reg <= ST_ABS_LO;
                                    AM_IND: state_reg <= ST_ABS_LO;
                                    AM_IZX: state_reg <= ST_IZX_ADDR;
                                    AM_IZY: state_reg <= ST_IZY_ADDR;
                                    AM_REL: state_reg <= ST_BRANCH_OP;
                                    default: state_reg <= ST_TRAP;
                                endcase
                            end
                        endcase
                    end
                end
                ST_IMM: begin
                    pc_reg <= pc_reg + 16'd1;
                    do_read_value(bus_din);
                    state_reg <= ST_FETCH;
                end
                ST_IMP: begin
                    do_implicit_value;
                    state_reg <= ST_FETCH;
                end
                ST_ZP_ADDR: begin
                    operand_reg <= {8'h00, bus_din};
                    addr_reg <= {8'h00, bus_din};
                    pc_reg <= pc_reg + 16'd1;
                    state_reg <= ST_DATA;
                end
                ST_ZPI_ADDR: begin
                    operand_reg <= {8'h00, bus_din};
                    pc_reg <= pc_reg + 16'd1;
                    state_reg <= ST_ZPI_DUMMY;
                end
                ST_ZPI_DUMMY: begin
                    addr_reg <= {8'h00, add_zp_index(operand_reg[7:0], selected_index)};
                    state_reg <= ST_DATA;
                end
                ST_DATA: begin
                    if (access_reg == ACCESS_WRITE) begin
                        state_reg <= ST_FETCH;
                    end else if (access_reg == ACCESS_RMW) begin
                        rmw_data_reg <= bus_din;
                        rmw_addr_reg <= addr_reg;
                        state_reg <= ST_RMW_OLD_WRITE;
                    end else begin
                        do_read_value(bus_din);
                        state_reg <= ST_FETCH;
                    end
                end
                ST_ABS_LO: begin
                    operand_reg[7:0] <= bus_din;
                    pc_reg <= pc_reg + 16'd1;
                    state_reg <= ST_ABS_HI;
                end
                ST_ABS_HI: begin
                    operand_reg <= {bus_din, operand_reg[7:0]};
                    if (class_reg == C_JMP) begin
                        if (mode_reg == AM_IND) begin
                            pc_reg <= pc_reg + 16'd1;
                            state_reg <= ST_JMP_IND_LO;
                        end else begin
                            pc_reg <= {bus_din, operand_reg[7:0]};
                            state_reg <= ST_FETCH;
                        end
                    end else if ((mode_reg == AM_ABX) || (mode_reg == AM_ABY)) begin
                        pc_reg <= pc_reg + 16'd1;
                        if ((access_reg == ACCESS_READ) && (abs_base_from_bus[15:8] == abs_indexed_from_bus[15:8])) begin
                            addr_reg <= abs_indexed_from_bus;
                            state_reg <= ST_DATA;
                        end else begin
                            addr_reg <= abs_wrong_from_bus;
                            state_reg <= ST_ABI_DUMMY;
                        end
                    end else begin
                        pc_reg <= pc_reg + 16'd1;
                        addr_reg <= {bus_din, operand_reg[7:0]};
                        state_reg <= ST_DATA;
                    end
                end
                ST_ABI_DUMMY: begin
                    addr_reg <= abs_indexed_addr;
                    state_reg <= ST_DATA;
                end
                ST_IZX_ADDR: begin
                    operand_reg <= {8'h00, bus_din};
                    ptr_reg <= {8'h00, bus_din + x_reg};
                    pc_reg <= pc_reg + 16'd1;
                    state_reg <= ST_IZX_DUMMY;
                end
                ST_IZX_DUMMY: begin
                    state_reg <= ST_IZX_LO;
                end
                ST_IZX_LO: begin
                    operand_reg <= {8'h00, bus_din};
                    state_reg <= ST_IZX_HI;
                end
                ST_IZX_HI: begin
                    operand_reg <= {bus_din, operand_reg[7:0]};
                    addr_reg <= {bus_din, operand_reg[7:0]};
                    state_reg <= ST_DATA;
                end
                ST_IZY_ADDR: begin
                    ptr_reg <= {8'h00, bus_din};
                    pc_reg <= pc_reg + 16'd1;
                    state_reg <= ST_IZY_LO;
                end
                ST_IZY_LO: begin
                    operand_reg <= {8'h00, bus_din};
                    state_reg <= ST_IZY_HI;
                end
                ST_IZY_HI: begin
                    operand_reg <= izy_base_from_bus;
                    if ((access_reg == ACCESS_READ) && (izy_base_from_bus[15:8] == izy_fixed_from_bus[15:8])) begin
                        addr_reg <= izy_fixed_from_bus;
                        state_reg <= ST_DATA;
                    end else begin
                        addr_reg <= izy_wrong_from_bus;
                        state_reg <= ST_IZY_DUMMY;
                    end
                end
                ST_IZY_DUMMY: begin
                    addr_reg <= izy_fixed_addr;
                    state_reg <= ST_DATA;
                end
                ST_BRANCH_OP: begin
                    operand_reg <= {8'h00, bus_din};
                    branch_target_reg <= add_signed_offset(pc_reg + 16'd1, bus_din);
                    pc_reg <= pc_reg + 16'd1;
                    if (branch_take(opcode_reg, p_reg))
                        state_reg <= ST_BRANCH_DUMMY;
                    else
                        state_reg <= ST_FETCH;
                end
                ST_BRANCH_DUMMY: begin
                    if (branch_target_reg[15:8] != pc_reg[15:8])
                        state_reg <= ST_BRANCH_CROSS;
                    else begin
                        pc_reg <= branch_target_reg;
                        state_reg <= ST_FETCH;
                    end
                end
                ST_BRANCH_CROSS: begin
                    pc_reg <= branch_target_reg;
                    state_reg <= ST_FETCH;
                end
                ST_RMW_OLD_WRITE: begin
                    state_reg <= ST_RMW_WRITE;
                end
                ST_RMW_WRITE: begin
                    do_rmw_value;
                    state_reg <= ST_FETCH;
                end
                ST_JMP_IND_LO: begin
                    addr_reg <= {8'h00, bus_din};
                    state_reg <= ST_JMP_IND_HI;
                end
                ST_JMP_IND_HI: begin
                    pc_reg <= {bus_din, addr_reg[7:0]};
                    state_reg <= ST_FETCH;
                end
                ST_JSR_LO: begin
                    operand_reg <= {8'h00, bus_din};
                    pc_reg <= pc_reg + 16'd1;
                    state_reg <= ST_JSR_STACK;
                end
                ST_JSR_STACK: begin
                    state_reg <= ST_JSR_PUSH_HI;
                end
                ST_JSR_PUSH_HI: begin
                    sp_reg <= sp_reg - 8'd1;
                    state_reg <= ST_JSR_PUSH_LO;
                end
                ST_JSR_PUSH_LO: begin
                    sp_reg <= sp_reg - 8'd1;
                    state_reg <= ST_JSR_HI;
                end
                ST_JSR_HI: begin
                    pc_reg <= {bus_din, operand_reg[7:0]};
                    state_reg <= ST_FETCH;
                end
                ST_RTS_DUMMY: begin
                    state_reg <= ST_RTS_STACK;
                end
                ST_RTS_STACK: begin
                    state_reg <= ST_RTS_LO;
                end
                ST_RTS_LO: begin
                    addr_reg <= {8'h00, bus_din};
                    sp_reg <= sp_reg + 8'd1;
                    state_reg <= ST_RTS_HI;
                end
                ST_RTS_HI: begin
                    pc_reg <= {bus_din, addr_reg[7:0]};
                    sp_reg <= sp_reg + 8'd1;
                    state_reg <= ST_RTS_INC;
                end
                ST_RTS_INC: begin
                    pc_reg <= pc_reg + 16'd1;
                    state_reg <= ST_FETCH;
                end
                ST_RTI_DUMMY: begin
                    state_reg <= ST_RTI_STACK;
                end
                ST_RTI_STACK: begin
                    state_reg <= ST_RTI_P;
                end
                ST_RTI_P: begin
                    p_reg <= (bus_din & 8'hEF) | 8'h20;
                    sp_reg <= sp_reg + 8'd1;
                    state_reg <= ST_RTI_LO;
                end
                ST_RTI_LO: begin
                    addr_reg <= {8'h00, bus_din};
                    sp_reg <= sp_reg + 8'd1;
                    state_reg <= ST_RTI_HI;
                end
                ST_RTI_HI: begin
                    pc_reg <= {bus_din, addr_reg[7:0]};
                    sp_reg <= sp_reg + 8'd1;
                    state_reg <= ST_FETCH;
                end
                ST_PUSH_DUMMY: begin
                    state_reg <= ST_PUSH;
                end
                ST_PUSH: begin
                    sp_reg <= sp_reg - 8'd1;
                    state_reg <= ST_FETCH;
                end
                ST_PULL_DUMMY: begin
                    state_reg <= ST_PULL_STACK;
                end
                ST_PULL_STACK: begin
                    state_reg <= ST_PULL;
                end
                ST_PULL: begin
                    if (class_reg == C_PULL_A) begin
                        a_reg <= bus_din;
                        p_reg[1] <= (bus_din == 8'h00);
                        p_reg[7] <= bus_din[7];
                    end else begin
                        p_reg <= (bus_din & 8'hEF) | 8'h20;
                    end
                    sp_reg <= sp_reg + 8'd1;
                    state_reg <= ST_FETCH;
                end
                ST_BRK_DUMMY: begin
                    pc_reg <= pc_reg + 16'd1;
                    int_pc_push_reg <= pc_reg + 16'd1;
                    state_reg <= ST_INT_PUSH_HI;
                end
                ST_INT_DUMMY2: begin
                    state_reg <= ST_INT_PUSH_HI;
                end
                ST_INT_PUSH_HI: begin
                    sp_reg <= sp_reg - 8'd1;
                    state_reg <= ST_INT_PUSH_LO;
                end
                ST_INT_PUSH_LO: begin
                    sp_reg <= sp_reg - 8'd1;
                    if (nmi_pending_reg &&
                        ((int_kind_reg == INT_BRK) || (int_kind_reg == INT_IRQ))) begin
                        int_kind_reg <= INT_NMI;
                        int_push_b_reg <= 1'b0;
                        if (!nmi_rise)
                            nmi_pending_reg <= 1'b0;
                    end
                    state_reg <= ST_INT_PUSH_P;
                end
                ST_INT_PUSH_P: begin
                    p_reg[2] <= 1'b1;
                    sp_reg <= sp_reg - 8'd1;
                    state_reg <= ST_INT_VEC_LO;
                end
                ST_INT_VEC_LO: begin
                    vector_reg[7:0] <= bus_din;
                    state_reg <= ST_INT_VEC_HI;
                end
                ST_INT_VEC_HI: begin
                    pc_reg <= {bus_din, vector_reg[7:0]};
                    if ((int_kind_reg == INT_NMI) && !nmi_rise)
                        nmi_pending_reg <= 1'b0;
                    int_kind_reg <= INT_NONE;
                    int_push_b_reg <= 1'b0;
                    state_reg <= ST_FETCH;
                end
                ST_TRAP: begin
                end
                default: begin
                    illegal_reg <= 1'b1;
                    state_reg <= ST_TRAP;
                end
            endcase
        end
    end
end

endmodule
