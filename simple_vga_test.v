module simple_vga_test (
    input  wire CLOCK_50,
    input  wire [3:0] KEY,
    input  wire [9:0] SW,

    // External GPIO header for keypad/buttons.
    // P2 keypad mapping in this file:
    // GPIO_0[0] = P2 left, GPIO_0[1] = P2 right, GPIO_0[2] = P2 attack
    // These three inputs are expected to be active-low.
    inout  wire [35:0] GPIO_0GPIO,

    output wire VGA_HS,
    output wire VGA_VS,
    output wire [7:0] VGA_R,
    output wire [7:0] VGA_G,

    output wire [7:0] VGA_B,
    output wire VGA_CLK,
    output wire VGA_BLANK_N,
    output wire VGA_SYNC_N,

    output wire [9:0] LEDR,
    output wire [6:0] HEX0,
    output wire [6:0] HEX1,
    output wire [6:0] HEX2,
    output wire [6:0] HEX3,
    output wire [6:0] HEX4,
    output wire [6:0] HEX5
);

    // ---------------- Clock / reset ----------------
    reg clk_25mhz;
    reg [7:0] reset_counter;
    reg reset_sig;
    reg [7:0] blink_timer;

    initial begin
        clk_25mhz = 1'b0;
        reset_counter = 8'd0;
        reset_sig = 1'b1;
        blink_timer = 8'd0;
    end

    always @(posedge CLOCK_50)
        clk_25mhz <= ~clk_25mhz;

    always @(posedge clk_25mhz) begin
        if (SW[9]) begin
            reset_counter <= 8'd0;
            reset_sig <= 1'b1;
        end else if (reset_counter < 8'd200) begin
            reset_counter <= reset_counter + 8'd1;
            reset_sig <= 1'b1;
        end else begin
            reset_sig <= 1'b0;
        end
    end

    // ---------------- VGA ----------------
    wire [9:0] next_x, next_y;
    wire vsync_out;
    reg [7:0] current_color;

    assign VGA_VS = vsync_out;

    vga_driver driver_inst (
        .clock(clk_25mhz),
        .reset(reset_sig),
        .color_in(current_color),
        .next_x(next_x),
        .next_y(next_y),
        .hsync(VGA_HS),
        .vsync(vsync_out),
        .red(VGA_R),
        .green(VGA_G),
        .blue(VGA_B),
        .sync(VGA_SYNC_N),
        .clk(VGA_CLK),
        .blank(VGA_BLANK_N)
    );

    // Debounced control signals. Debouncing is done before the game FSM sees inputs.
    wire p1_left_db, p1_right_db, p1_attack_db;
    wire p2_left_db, p2_right_db, p2_attack_db;
    wire manual_step_db;

    // P1 stays on the onboard controls:
    // P1 left = SW[5], P1 right = SW[4], P1 attack = KEY[1] active-low.
    debounce_signal db_p1_left   (.clk(clk_25mhz), .rst(reset_sig), .noisy(~KEY[1]),  .clean(p1_left_db));
    debounce_signal db_p1_right  (.clk(clk_25mhz), .rst(reset_sig), .noisy(~KEY[0]),  .clean(p1_right_db));
    debounce_signal db_p1_attack (.clk(clk_25mhz), .rst(reset_sig), .noisy(~KEY[3]), .clean(p1_attack_db));

    // P2 is read from three active-low GPIO keypad/button lines.
    // GPIO_0[0] = left, GPIO_0[1] = right, GPIO_0[2] = attack.
    wire p2_left_gpio_raw, p2_right_gpio_raw, p2_attack_gpio_raw;

    player_input p2_keypad_input (
        .game_clk(clk_25mhz),
        .reset(reset_sig),
        .gpio_left(GPIO_0GPIO[0]),
        .gpio_right(GPIO_0GPIO[1]),
        .gpio_attack(GPIO_0GPIO[2]),
        .left(p2_left_gpio_raw),
        .right(p2_right_gpio_raw),
        .attack(p2_attack_gpio_raw)
    );

    debounce_signal db_p2_left   (.clk(clk_25mhz), .rst(reset_sig), .noisy(p2_left_gpio_raw),   .clean(p2_left_db));
    debounce_signal db_p2_right  (.clk(clk_25mhz), .rst(reset_sig), .noisy(p2_right_gpio_raw),  .clean(p2_right_db));
    debounce_signal db_p2_attack (.clk(clk_25mhz), .rst(reset_sig), .noisy(p2_attack_gpio_raw), .clean(p2_attack_db));

    debounce_signal db_manual    (.clk(clk_25mhz), .rst(reset_sig), .noisy(~KEY[2]), .clean(manual_step_db));

    // Mandatory debug mode: SW[1] selects 60 Hz game clock or manual KEY[2].
    wire game_clk_60hz   = ~vsync_out;
    wire game_clk_manual = manual_step_db;
    wire game_logic_clk  = SW[1] ? game_clk_manual : game_clk_60hz;

    always @(posedge game_clk_60hz or posedge reset_sig) begin
        if (reset_sig)
            blink_timer <= 8'd0;
        else
            blink_timer <= blink_timer + 8'd1;
    end

    // ---------------- Game core ----------------
    wire [9:0] p1_x, p2_x;
    wire [3:0] p1_state_w, p2_state_w;
    wire [1:0] p1_hp_w, p2_hp_w, p1_bp_w, p2_bp_w, p1_wins_w, p2_wins_w;
    wire [2:0] match_state_w;
    wire [7:0] countdown_w;
    wire [1:0] p1_side_w, p2_side_w;

    move movement_inst (
        .clk(game_logic_clk),
        .rst(reset_sig),

        // Control map:
        // P1: SW[5] left, SW[4] right, KEY[1] attack.
        // P2: GPIO_0[0] left, GPIO_0[1] right, GPIO_0[2] attack.
        .p1_left(p1_left_db),
        .p1_right(p1_right_db),
        .p1_attack(p1_attack_db),

        .p2_left(p2_left_db),
        .p2_right(p2_right_db),
        .p2_attack(p2_attack_db),

        .p1_pos_x(p1_x),
        .p2_pos_x(p2_x),
        .p1_state(p1_state_w),
        .p2_state(p2_state_w),
        .p1_hp(p1_hp_w),
        .p2_hp(p2_hp_w),
        .p1_bp(p1_bp_w),
        .p2_bp(p2_bp_w),
        .match_state(match_state_w),
        .countdown_timer(countdown_w),
        .p1_wins(p1_wins_w),
        .p2_wins(p2_wins_w),
        .p1_side(p1_side_w),
        .p2_side(p2_side_w)
    );

    // ---------------- Constants ----------------
    parameter BOX_W = 64;
    parameter BOX_H = 240;
    parameter Y_START = 200;
    parameter FLOOR_Y = Y_START + BOX_H;
    parameter HITBOX_Y_START = Y_START + 92;

    localparam ST_IDLE        = 4'd0;
    localparam ST_STARTUP     = 4'd1;
    localparam ST_ACTIVE      = 4'd2;
    localparam ST_RECOVERY    = 4'd3;
    localparam ST_HITSTUN     = 4'd4;
    localparam ST_BLOCKSTUN   = 4'd5;
    localparam ST_GUARDBREAK  = 4'd6;
    localparam ST_SP_STARTUP  = 4'd7;
    localparam ST_SP_ACTIVE   = 4'd8;
    localparam ST_SP_RECOVERY = 4'd9;
    localparam ST_MOVE_FWD    = 4'd10;
    localparam ST_MOVE_BACK   = 4'd11;

    localparam MATCH_MENU      = 3'd0;
    localparam MATCH_COUNTDOWN = 3'd1;
    localparam MATCH_PLAYING   = 3'd2;
    localparam MATCH_KO        = 3'd3;
    localparam MATCH_GAMEOVER  = 3'd4;
    localparam MATCH_DRAW      = 3'd5;

    wire game_over = (match_state_w == MATCH_GAMEOVER);
    wire left_is_p1  = (p1_side_w == 2'd0);
    wire left_is_p2  = (p2_side_w == 2'd0);
    wire right_is_p1 = (p1_side_w == 2'd1);
    wire right_is_p2 = (p2_side_w == 2'd1);

    // Visual-only helpers: animated stars, compact HUD feedback, and charge bars.
    reg [6:0] star_scroll;
    reg [5:0] left_charge_vis, right_charge_vis;

    wire ctrl_p1_attack = p1_attack_db;
    wire ctrl_p2_attack = p2_attack_db;
    wire left_char_attack  = left_is_p1  ? ctrl_p1_attack : (left_is_p2  ? ctrl_p2_attack : 1'b0);
    wire right_char_attack = right_is_p1 ? ctrl_p1_attack : (right_is_p2 ? ctrl_p2_attack : 1'b0);
    // Visual charge follows the same hold duration used by move.v.
    // It keeps filling while the attack button is held, even if the press already started a basic attack.
    wire left_charge_enable  = left_char_attack  && (match_state_w == MATCH_PLAYING);
    wire right_charge_enable = right_char_attack && (match_state_w == MATCH_PLAYING);

    always @(posedge game_clk_60hz or posedge reset_sig) begin
        if (reset_sig) begin
            star_scroll <= 7'd0;
            left_charge_vis <= 6'd0;
            right_charge_vis <= 6'd0;
        end else begin
            star_scroll <= star_scroll + 7'd1;

            if ((match_state_w == MATCH_PLAYING) || (match_state_w == MATCH_COUNTDOWN)) begin
                if (left_charge_enable && (left_charge_vis < 6'd36))
                    left_charge_vis <= left_charge_vis + 6'd1;
                else if (!left_char_attack)
                    left_charge_vis <= 6'd0;

                if (right_charge_enable && (right_charge_vis < 6'd36))
                    right_charge_vis <= right_charge_vis + 6'd1;
                else if (!right_char_attack)
                    right_charge_vis <= 6'd0;
            end else begin
                left_charge_vis <= 6'd0;
                right_charge_vis <= 6'd0;
            end
        end
    end

    // ---------------- Helpers ----------------
    function inr;
        input [9:0] x;
        input [9:0] y;
        input integer x0;
        input integer x1;
        input integer y0;
        input integer y1;
        begin
            inr = (x >= x0) && (x <= x1) && (y >= y0) && (y <= y1);
        end
    endfunction

    function draw_1;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_1 = inr(x,y,x0+8,x0+13,y0,y0+40) || inr(x,y,x0,x0+8,y0,y0+5);
        end
    endfunction
    function draw_2;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_2 = inr(x,y,x0,x0+24,y0,y0+5) ||
                     inr(x,y,x0+19,x0+24,y0,y0+20) ||
                     inr(x,y,x0,x0+24,y0+18,y0+23) ||
                     inr(x,y,x0,x0+5,y0+18,y0+40) ||
                     inr(x,y,x0,x0+24,y0+35,y0+40);
        end
    endfunction
    function draw_3;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_3 = inr(x,y,x0,x0+24,y0,y0+5) ||
                     inr(x,y,x0+19,x0+24,y0,y0+40) ||
                     inr(x,y,x0,x0+24,y0+18,y0+23) ||
                     inr(x,y,x0,x0+24,y0+35,y0+40);
        end
    endfunction
    function draw_A;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_A = inr(x,y,x0,x0+5,y0+4,y0+40) ||
                     inr(x,y,x0+19,x0+24,y0+4,y0+40) ||
                     inr(x,y,x0,x0+24,y0,y0+5) ||
                     inr(x,y,x0,x0+24,y0+18,y0+23);
        end
    endfunction
    function draw_D;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_D = inr(x,y,x0,x0+5,y0,y0+40) ||
                     inr(x,y,x0,x0+18,y0,y0+5) ||
                     inr(x,y,x0,x0+18,y0+35,y0+40) ||
                     inr(x,y,x0+18,x0+24,y0+5,y0+35);
        end
    endfunction
    function draw_E;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_E = inr(x,y,x0,x0+5,y0,y0+40) ||
                     inr(x,y,x0,x0+24,y0,y0+5) ||
                     inr(x,y,x0,x0+20,y0+18,y0+23) ||
                     inr(x,y,x0,x0+24,y0+35,y0+40);
        end
    endfunction
    function draw_G;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_G = inr(x,y,x0,x0+24,y0,y0+5) ||
                     inr(x,y,x0,x0+5,y0,y0+40) ||
                     inr(x,y,x0,x0+24,y0+35,y0+40) ||
                     inr(x,y,x0+18,x0+24,y0+20,y0+40) ||
                     inr(x,y,x0+10,x0+24,y0+18,y0+23);
        end
    endfunction
    function draw_I;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_I = inr(x,y,x0,x0+24,y0,y0+5) ||
                     inr(x,y,x0+10,x0+15,y0,y0+40) ||
                     inr(x,y,x0,x0+24,y0+35,y0+40);
        end
    endfunction
    function draw_K;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            // More readable blocky K: strong left stem + stepped diagonals.
            draw_K = inr(x,y,x0,x0+5,y0,y0+40) ||
                     inr(x,y,x0+18,x0+24,y0,y0+8) ||
                     inr(x,y,x0+13,x0+19,y0+8,y0+16) ||
                     inr(x,y,x0+8,x0+14,y0+16,y0+24) ||
                     inr(x,y,x0+13,x0+19,y0+24,y0+32) ||
                     inr(x,y,x0+18,x0+24,y0+32,y0+40);
        end
    endfunction
    function draw_M;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_M = inr(x,y,x0,x0+5,y0,y0+40) ||
                     inr(x,y,x0+24,x0+29,y0,y0+40) ||
                     inr(x,y,x0+6,x0+11,y0+4,y0+14) ||
                     inr(x,y,x0+12,x0+17,y0+12,y0+24) ||
                     inr(x,y,x0+18,x0+23,y0+4,y0+14);
        end
    endfunction
        function draw_N;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_N = inr(x,y,x0,x0+5,y0,y0+40) ||
                     inr(x,y,x0+24,x0+29,y0,y0+40) ||
                     inr(x,y,x0+7,x0+12,y0+6,y0+14) ||
                     inr(x,y,x0+13,x0+18,y0+16,y0+24) ||
                     inr(x,y,x0+19,x0+24,y0+26,y0+34);
        end
    endfunction
    function draw_O;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_O = inr(x,y,x0,x0+24,y0,y0+5) ||
                     inr(x,y,x0,x0+24,y0+35,y0+40) ||
                     inr(x,y,x0,x0+5,y0,y0+40) ||
                     inr(x,y,x0+19,x0+24,y0,y0+40);
        end
    endfunction
    function draw_P;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_P = inr(x,y,x0,x0+5,y0,y0+40) ||
                     inr(x,y,x0,x0+24,y0,y0+5) ||
                     inr(x,y,x0,x0+24,y0+18,y0+23) ||
                     inr(x,y,x0+19,x0+24,y0,y0+23);
        end
    endfunction
    function draw_R;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            // Clearer R: P-shaped top plus a thicker stepped diagonal leg.
            draw_R = draw_P(x,y,x0,y0) ||
                     inr(x,y,x0+10,x0+15,y0+22,y0+28) ||
                     inr(x,y,x0+15,x0+20,y0+28,y0+34) ||
                     inr(x,y,x0+20,x0+25,y0+34,y0+40);
        end
    endfunction
    function draw_S;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_S = inr(x,y,x0,x0+24,y0,y0+5) ||
                     inr(x,y,x0,x0+5,y0,y0+22) ||
                     inr(x,y,x0,x0+24,y0+18,y0+23) ||
                     inr(x,y,x0+19,x0+24,y0+18,y0+40) ||
                     inr(x,y,x0,x0+24,y0+35,y0+40);
        end
    endfunction
    function draw_T;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_T = inr(x,y,x0,x0+24,y0,y0+5) || inr(x,y,x0+10,x0+15,y0,y0+40);
        end
    endfunction
    function draw_U;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_U = inr(x,y,x0,x0+5,y0,y0+35) ||
                     inr(x,y,x0+19,x0+24,y0,y0+35) ||
                     inr(x,y,x0,x0+24,y0+35,y0+40);
        end
    endfunction
    function draw_V;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_V = inr(x,y,x0,x0+5,y0,y0+30) ||
                     inr(x,y,x0+19,x0+24,y0,y0+30) ||
                     inr(x,y,x0+6,x0+18,y0+35,y0+40);
        end
    endfunction
    function draw_W;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_W = inr(x,y,x0,x0+5,y0,y0+40) ||
                     inr(x,y,x0+24,x0+29,y0,y0+40) ||
                     inr(x,y,x0+8,x0+12,y0+24,y0+40) ||
                     inr(x,y,x0+16,x0+20,y0+24,y0+40);
        end
    endfunction

    function draw_B;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_B = inr(x,y,x0,x0+5,y0,y0+40) ||
                     inr(x,y,x0,x0+20,y0,y0+5) ||
                     inr(x,y,x0,x0+20,y0+18,y0+23) ||
                     inr(x,y,x0,x0+20,y0+35,y0+40) ||
                     inr(x,y,x0+18,x0+24,y0+5,y0+18) ||
                     inr(x,y,x0+18,x0+24,y0+23,y0+35);
        end
    endfunction
    function draw_C;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_C = inr(x,y,x0,x0+24,y0,y0+5) ||
                     inr(x,y,x0,x0+5,y0,y0+40) ||
                     inr(x,y,x0,x0+24,y0+35,y0+40);
        end
    endfunction
    function draw_H;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_H = inr(x,y,x0,x0+5,y0,y0+40) ||
                     inr(x,y,x0+19,x0+24,y0,y0+40) ||
                     inr(x,y,x0,x0+24,y0+18,y0+23);
        end
    endfunction
    function draw_L;
        input [9:0] x; input [9:0] y; input [9:0] x0; input [9:0] y0;
        begin
            draw_L = inr(x,y,x0,x0+5,y0,y0+40) ||
                     inr(x,y,x0,x0+24,y0+35,y0+40);
        end
    endfunction

    function msg_START;
        input [9:0] x; input [9:0] y;
        begin
            msg_START = draw_S(x,y,10'd195,10'd120) || draw_T(x,y,10'd230,10'd120) ||
                        draw_A(x,y,10'd265,10'd120) || draw_R(x,y,10'd300,10'd120) ||
                        draw_T(x,y,10'd335,10'd120);
        end
    endfunction
    function msg_DRAW;
        input [9:0] x; input [9:0] y;
        begin
            msg_DRAW = draw_D(x,y,10'd220,10'd110) || draw_R(x,y,10'd255,10'd110) ||
                       draw_A(x,y,10'd290,10'd110) || draw_W(x,y,10'd325,10'd110);
        end
    endfunction
    function msg_GAMEOVER;
        input [9:0] x; input [9:0] y;
        begin
            msg_GAMEOVER = draw_G(x,y,10'd185,10'd160) || draw_A(x,y,10'd220,10'd160) ||
                           draw_M(x,y,10'd255,10'd160) || draw_E(x,y,10'd295,10'd160) ||
                           draw_O(x,y,10'd340,10'd160) || draw_V(x,y,10'd375,10'd160) ||
                           draw_E(x,y,10'd410,10'd160) || draw_R(x,y,10'd445,10'd160);
        end
    endfunction
    function msg_WINS;
        input [9:0] x; input [9:0] y;
        begin
            msg_WINS = draw_W(x,y,10'd305,10'd110) || draw_I(x,y,10'd345,10'd110) ||
                       draw_N(x,y,10'd380,10'd110) || draw_S(x,y,10'd420,10'd110);
        end
    endfunction

    function msg_HIT;
        input [9:0] x; input [9:0] y;
        begin
            msg_HIT = draw_H(x,y,10'd276,10'd70) || draw_I(x,y,10'd311,10'd70) || draw_T(x,y,10'd346,10'd70);
        end
    endfunction
    function msg_BLOCK;
        input [9:0] x; input [9:0] y;
        begin
            msg_BLOCK = draw_B(x,y,10'd240,10'd70) || draw_L(x,y,10'd275,10'd70) || draw_O(x,y,10'd305,10'd70) ||
                        draw_C(x,y,10'd340,10'd70) || draw_K(x,y,10'd372,10'd70);
        end
    endfunction
    function msg_BREAK;
        input [9:0] x; input [9:0] y;
        begin
            msg_BREAK = draw_B(x,y,10'd210,10'd70) || draw_R(x,y,10'd245,10'd70) || draw_E(x,y,10'd280,10'd70) ||
                        draw_A(x,y,10'd315,10'd70) || draw_K(x,y,10'd350,10'd70);
        end
    endfunction
    function msg_DEBUGMODE;
        input [9:0] x; input [9:0] y;
        begin
            msg_DEBUGMODE = draw_D(x,y,10'd172,10'd14) || draw_E(x,y,10'd202,10'd14) || draw_B(x,y,10'd232,10'd14) ||
                            draw_U(x,y,10'd262,10'd14) || draw_G(x,y,10'd292,10'd14) ||
                            draw_M(x,y,10'd340,10'd14) || draw_O(x,y,10'd380,10'd14) || draw_D(x,y,10'd415,10'd14) || draw_E(x,y,10'd445,10'd14);
        end
    endfunction

    // Generic mirrored sprite function. x increases toward the opponent for both players.
    function sprite_body;
        input [3:0] st;
        input [9:0] x;
        input [9:0] y;
        input phase;
        begin
            case (st)
                ST_IDLE: begin
                    sprite_body = inr(x,y,22,40,18,42) ||  // head
                                  inr(x,y,20,42,44,118) || // torso
                                  inr(x,y,12,48,64,74)  || // crossed arms
                                  inr(x,y,18,26,120,220) ||
                                  inr(x,y,36,44,120,220) ||
                                  (phase ? inr(x,y,28,34,8,17) : inr(x,y,26,32,10,19));
                end
                ST_MOVE_FWD: begin
                    // Two-frame walk cycle with thinner legs.
                    sprite_body = inr(x,y,24,42,18,42) ||
                                  inr(x,y,22,44,44,118) ||
                                  (phase ? inr(x,y,8,30,84,92)  : inr(x,y,12,34,72,80)) ||
                                  (phase ? inr(x,y,30,56,70,78) : inr(x,y,28,52,88,96)) ||
                                  (phase ? inr(x,y,18,24,120,210) : inr(x,y,28,34,120,224)) ||
                                  (phase ? inr(x,y,42,48,120,224) : inr(x,y,16,22,120,210));
                end
                ST_MOVE_BACK: begin
                    // Guarded backward walk cycle with thinner legs.
                    sprite_body = inr(x,y,22,40,18,42) ||
                                  inr(x,y,20,42,44,118) ||
                                  inr(x,y,12,44,58,68)  ||
                                  inr(x,y,16,46,74,84)  ||
                                  (phase ? inr(x,y,22,28,120,220) : inr(x,y,30,36,120,210)) ||
                                  (phase ? inr(x,y,38,44,120,210) : inr(x,y,16,22,120,220));
                end
                ST_STARTUP: begin
                    sprite_body = inr(x,y,20,38,30,54) ||
                                  inr(x,y,16,40,56,110) ||
                                  inr(x,y,8,28,86,96)  ||
                                  inr(x,y,28,44,76,86) ||
                                  inr(x,y,18,32,112,180) ||
                                  inr(x,y,30,48,112,185);
                end
                ST_ACTIVE: begin
                    sprite_body = inr(x,y,22,40,18,42) ||
                                  inr(x,y,20,42,44,118) ||
                                  inr(x,y,10,28,72,82) ||
                                  inr(x,y,30,63,76,86) || // long punch
                                  inr(x,y,18,28,120,220) ||
                                  inr(x,y,38,48,120,220);
                end
                ST_RECOVERY: begin
                    sprite_body = inr(x,y,24,42,18,42) ||
                                  inr(x,y,24,46,44,118) ||
                                  inr(x,y,34,58,84,94) ||
                                  inr(x,y,20,30,120,215) ||
                                  inr(x,y,40,50,120,220);
                end
                ST_SP_STARTUP: begin
                    sprite_body = inr(x,y,16,34,42,62) ||
                                  inr(x,y,12,38,64,116) ||
                                  inr(x,y,6,24,94,104) ||
                                  inr(x,y,20,42,74,84) ||
                                  inr(x,y,14,28,118,175) ||
                                  inr(x,y,28,48,118,180);
                end
                ST_SP_ACTIVE: begin
                    sprite_body = inr(x,y,10,28,56,78) ||
                                  inr(x,y,24,54,62,104) ||
                                  inr(x,y,48,62,70,82) ||
                                  inr(x,y,6,20,92,102) ||
                                  inr(x,y,22,44,106,126) ||
                                  inr(x,y,42,62,112,126);
                end
                ST_SP_RECOVERY: begin
                    sprite_body = inr(x,y,14,32,54,76) ||
                                  inr(x,y,18,42,78,122) ||
                                  inr(x,y,36,54,88,98) ||
                                  inr(x,y,10,26,122,136) ||
                                  inr(x,y,24,44,126,142);
                end
                ST_HITSTUN: begin
                    sprite_body = inr(x,y,14,32,18,42) ||
                                  inr(x,y,10,34,44,118) ||
                                  inr(x,y,6,30,80,90) ||
                                  inr(x,y,18,28,120,220) ||
                                  inr(x,y,32,42,120,210);
                end
                ST_BLOCKSTUN: begin
                    sprite_body = inr(x,y,22,40,18,42) ||
                                  inr(x,y,20,42,44,118) ||
                                  inr(x,y,12,44,56,66) ||
                                  inr(x,y,14,46,72,82) ||
                                  inr(x,y,20,30,120,220) ||
                                  inr(x,y,34,44,120,220);
                end
                ST_GUARDBREAK: begin
                    sprite_body = inr(x,y,22,40,18,42) ||
                                  inr(x,y,20,42,44,118) ||
                                  inr(x,y,10,24,54,64) ||
                                  inr(x,y,38,52,54,64) ||
                                  inr(x,y,18,28,120,220) ||
                                  inr(x,y,36,46,120,220);
                end
                default: begin
                    sprite_body = 1'b0;
                end
            endcase
        end
    endfunction

    function sprite_fx;
        input [3:0] st;
        input [9:0] x;
        input [9:0] y;
        input phase;
        begin
            case (st)
                ST_ACTIVE: begin
                    sprite_fx = inr(x,y,56,63,68,90) || inr(x,y,52,58,64,98); // punch flash
                end
                ST_RECOVERY: begin
                    sprite_fx = inr(x,y,48,63,220,226) || inr(x,y,52,60,214,219); // slide dust
                end
                ST_SP_STARTUP: begin
                    sprite_fx = inr(x,y,6,10,70,130) || inr(x,y,44,48,70,130) ||
                                inr(x,y,12,42,64,68) || inr(x,y,12,42,132,136); // aura frame
                end
                ST_SP_ACTIVE: begin
                    sprite_fx = inr(x,y,2,8,82,102) || inr(x,y,0,5,74,110) ||
                                inr(x,y,52,63,62,96) || inr(x,y,56,63,72,86); // fire trail and kick spark
                end
                ST_SP_RECOVERY: begin
                    sprite_fx = inr(x,y,0,10,138,144) || inr(x,y,12,20,132,138);
                end
                ST_HITSTUN: begin
                    sprite_fx = inr(x,y,0,8,60,70) || inr(x,y,4,12,82,90) || inr(x,y,18,24,54,60); // sparks
                end
                ST_BLOCKSTUN: begin
                    sprite_fx = inr(x,y,0,8,56,66) || inr(x,y,2,10,72,82) || inr(x,y,6,14,88,96); // block impact
                end
                ST_GUARDBREAK: begin
                    sprite_fx = inr(x,y,8,12,4,10) || inr(x,y,20,24,0,6) || inr(x,y,32,36,6,12) || inr(x,y,44,48,2,8); // dizzy stars
                end
                default: begin
                    sprite_fx = 1'b0;
                end
            endcase
        end
    endfunction

    // ---------------- Background ----------------
    // Menu uses a softer sunset scene; gameplay uses a pastel night city.
    // The ground/grid is static; only small stars move.
    wire bg_ground  = (next_y >= FLOOR_Y);
    wire bg_horizon = (next_y >= FLOOR_Y-4) && (next_y <= FLOOR_Y+2);
    wire sky_top    = (next_y < 10'd120);
    wire sky_mid    = (next_y >= 10'd120) && (next_y < 10'd240);
    wire sky_low    = (next_y >= 10'd240) && (next_y < FLOOR_Y);

    wire play_sun = (next_x >= 10'd506) && (next_x <= 10'd580) &&
                    (next_y >= 10'd48)  && (next_y <= 10'd118) &&
                    !((next_y >= 10'd70 && next_y <= 10'd72) || (next_y >= 10'd88 && next_y <= 10'd90));

    // Buildings now sit on the stage floor instead of floating above it.
    wire bld1 = inr(next_x,next_y,16,68,244,FLOOR_Y-1);
    wire bld2 = inr(next_x,next_y,82,132,220,FLOOR_Y-1);
    wire bld3 = inr(next_x,next_y,148,194,258,FLOOR_Y-1);
    wire bld4 = inr(next_x,next_y,208,266,228,FLOOR_Y-1);
    wire bld5 = inr(next_x,next_y,284,336,266,FLOOR_Y-1);
    wire bld6 = inr(next_x,next_y,352,414,232,FLOOR_Y-1);
    wire bld7 = inr(next_x,next_y,430,486,248,FLOOR_Y-1);
    wire bld8 = inr(next_x,next_y,500,546,214,FLOOR_Y-1);
    wire bld9 = inr(next_x,next_y,560,620,258,FLOOR_Y-1);
    wire bg_building = bld1 || bld2 || bld3 || bld4 || bld5 || bld6 || bld7 || bld8 || bld9;
    wire bg_window = bg_building && ((next_x[4:1] == 4'd2) || (next_x[4:1] == 4'd7)) &&
                     ((next_y[4:2] == 3'd1) || (next_y[4:2] == 3'd5));

    // Static floor grid.
    wire bg_grid = bg_ground && ((next_x[5:0] <= 6'd1) || (next_y[4:0] <= 5'd1));

    // Small animated stars drift slowly. They are intentionally tiny and pastel.
    wire star1 = (next_x == (10'd40  + {3'd0, star_scroll})) && (next_y >= 10'd42) && (next_y <= 10'd44);
    wire star2 = (next_x == (10'd120 + {3'd0, star_scroll})) && (next_y >= 10'd68) && (next_y <= 10'd70);
    wire star3 = (next_x == (10'd210 + {3'd0, star_scroll})) && (next_y >= 10'd36) && (next_y <= 10'd38);
    wire star4 = (next_x == (10'd300 + {3'd0, star_scroll})) && (next_y >= 10'd84) && (next_y <= 10'd86);
    wire star5 = (next_x == (10'd388 + {3'd0, star_scroll})) && (next_y >= 10'd52) && (next_y <= 10'd54);
    wire star6 = (next_x == (10'd470 + {3'd0, star_scroll})) && (next_y >= 10'd74) && (next_y <= 10'd76);
    wire star7 = (next_x == (10'd548 + {3'd0, star_scroll})) && (next_y >= 10'd30) && (next_y <= 10'd32);
    wire bg_star = star1 || star2 || star3 || star4 || star5 || star6 || star7;

    // Menu sunset scene.
    wire menu_top     = (next_y < 10'd110);
    wire menu_mid     = (next_y >= 10'd110) && (next_y < 10'd220);
    wire menu_low     = (next_y >= 10'd220) && (next_y < 10'd360);
    wire menu_ground  = (next_y >= 10'd360);
    wire menu_sun     = (next_x >= 10'd255) && (next_x <= 10'd385) && (next_y >= 10'd78) && (next_y <= 10'd180) &&
                        !((next_y >= 10'd112 && next_y <= 10'd114) || (next_y >= 10'd138 && next_y <= 10'd140));
    wire menu_hill_l  = (next_y >= 10'd305) && (next_y >= (10'd360 - (next_x >> 2))) && (next_x <= 10'd255);
    wire menu_hill_r  = (next_y >= 10'd305) && (next_y >= (10'd200 + ((next_x - 10'd255) >> 2))) && (next_x >= 10'd255);
    wire menu_star    = (((next_x + {3'd0, star_scroll}) & 10'd127) == 10'd10) && (next_y < 10'd80);

    // Soft hit/block/guard-break flash only during active gameplay.
    // It is intentionally not white anymore and it is disabled on KO/game over.
    wire impact_hit   = (match_state_w == MATCH_PLAYING) && ((p1_state_w == ST_HITSTUN) || (p2_state_w == ST_HITSTUN));
    wire impact_block = (match_state_w == MATCH_PLAYING) && ((p1_state_w == ST_BLOCKSTUN) || (p2_state_w == ST_BLOCKSTUN));
    wire impact_break = (match_state_w == MATCH_PLAYING) && ((p1_state_w == ST_GUARDBREAK) || (p2_state_w == ST_GUARDBREAK));
    wire flash_hit    = impact_hit && blink_timer[1];
    wire flash_warm   = impact_block && blink_timer[1];
    wire flash_break  = impact_break && blink_timer[1];

    wire [7:0] bg_color = (match_state_w == MATCH_MENU) ?
                          (menu_star   ? 8'b111_111_11 :
                           menu_sun    ? 8'b111_110_01 :
                           menu_hill_l ? 8'b010_010_10 :
                           menu_hill_r ? 8'b011_010_10 :
                           menu_ground ? 8'b010_010_01 :
                           menu_top    ? 8'b101_011_10 :
                           menu_mid    ? 8'b110_100_10 :
                           menu_low    ? 8'b100_100_10 : 8'b000_000_00) :
                          bg_star      ? 8'b111_111_11 :
                          play_sun     ? 8'b111_110_10 :
                          bg_window    ? 8'b101_111_11 :
                          bg_building  ? 8'b011_010_10 :
                          bg_horizon   ? 8'b101_100_10 :
                          bg_grid      ? 8'b100_111_11 :
                          bg_ground    ? 8'b010_010_01 :
                          sky_top      ? 8'b011_010_10 :
                          sky_mid      ? 8'b100_011_10 :
                          sky_low      ? 8'b100_100_10 :
                                         8'b000_000_00;

    // ---------------- HUD / LEDs / HEX ----------------
    wire [1:0] left_wins  = p1_wins_w;
    wire [1:0] right_wins = p2_wins_w;
    wire [2:0] left_leds  = (left_wins == 3) ? 3'b111 : (left_wins == 2) ? 3'b110 : (left_wins == 1) ? 3'b100 : 3'b000;
    wire [2:0] right_leds = (right_wins == 3) ? 3'b111 : (right_wins == 2) ? 3'b011 : (right_wins == 1) ? 3'b001 : 3'b000;

    assign LEDR = (match_state_w == MATCH_MENU) ? 10'd0 :
                  (match_state_w == MATCH_GAMEOVER) ? {10{blink_timer[5]}} :
                  {left_leds, 4'b0000, right_leds};

    // Old HEX behavior preserved and corrected for side selection.
    // Menu: show which controller is on the left/right side.
    // Game over: show P<winning controller> - 3 - <loser score>.
    wire [6:0] hex_P    = 7'h0C;
    wire [6:0] hex_0    = 7'hC0;
    wire [6:0] hex_1    = 7'hF9;
    wire [6:0] hex_2    = 7'hA4;
    wire [6:0] hex_3    = 7'hB0;
    wire [6:0] hex_dash = 7'hBF;
    wire [6:0] hex_V    = 7'hC1;
    wire [6:0] hex_S    = 7'h92;

    wire left_conflict  = (p1_side_w == 2'd0) && (p2_side_w == 2'd0);
    wire right_conflict = (p1_side_w == 2'd1) && (p2_side_w == 2'd1);

    wire left_match_won  = (p1_wins_w == 2'd3);
    wire right_match_won = (p2_wins_w == 2'd3);

    wire winner_is_ctrl_p1 = (left_match_won && left_is_p1) || (right_match_won && right_is_p1);
    wire winner_is_ctrl_p2 = (left_match_won && left_is_p2) || (right_match_won && right_is_p2);

    wire [1:0] loser_score = left_match_won ? p2_wins_w : p1_wins_w;
    wire [6:0] hex_loser_score = (loser_score == 2'd0) ? hex_0 :
                                  (loser_score == 2'd1) ? hex_1 :
                                  (loser_score == 2'd2) ? hex_2 : hex_3;

    wire [6:0] left_num_hex  = left_conflict  ? hex_dash : (left_is_p1  ? hex_1 : (left_is_p2  ? hex_2 : hex_dash));
    wire [6:0] left_p_hex    = left_conflict  ? hex_dash : ((left_is_p1 || left_is_p2) ? hex_P : hex_dash);
    wire [6:0] right_num_hex = right_conflict ? hex_dash : (right_is_p1 ? hex_1 : (right_is_p2 ? hex_2 : hex_dash));
    wire [6:0] right_p_hex   = right_conflict ? hex_dash : ((right_is_p1 || right_is_p2) ? hex_P : hex_dash);

    wire gameplay_hex_mode = (match_state_w != MATCH_MENU) && (match_state_w != MATCH_GAMEOVER);
    wire [6:0] gameplay_left_num_hex  = left_is_p1  ? hex_1 : (left_is_p2  ? hex_2 : hex_dash);
    wire [6:0] gameplay_right_num_hex = right_is_p1 ? hex_1 : (right_is_p2 ? hex_2 : hex_dash);

    assign HEX5 = game_over ? hex_P : (gameplay_hex_mode ? hex_P : left_p_hex);
    assign HEX4 = game_over ? (winner_is_ctrl_p1 ? hex_1 : (winner_is_ctrl_p2 ? hex_2 : hex_dash)) :
                  (gameplay_hex_mode ? gameplay_left_num_hex : left_num_hex);
    assign HEX3 = game_over ? hex_dash : (gameplay_hex_mode ? hex_V : hex_dash);
    assign HEX2 = game_over ? hex_3 : (gameplay_hex_mode ? hex_S : hex_dash);
    assign HEX1 = game_over ? hex_dash : (gameplay_hex_mode ? hex_P : right_p_hex);
    assign HEX0 = game_over ? hex_loser_score : (gameplay_hex_mode ? gameplay_right_num_hex : right_num_hex);

    // HUD boxes
    wire l_hp1 = inr(next_x,next_y,100,112,16,28);
    wire l_hp2 = inr(next_x,next_y,116,128,16,28);
    wire l_hp3 = inr(next_x,next_y,132,144,16,28);
    wire l_bp1 = inr(next_x,next_y,100,112,40,52);
    wire l_bp2 = inr(next_x,next_y,116,128,40,52);
    wire l_bp3 = inr(next_x,next_y,132,144,40,52);
    wire r_hp1 = inr(next_x,next_y,496,508,16,28);
    wire r_hp2 = inr(next_x,next_y,512,524,16,28);
    wire r_hp3 = inr(next_x,next_y,528,540,16,28);
    wire r_bp1 = inr(next_x,next_y,496,508,40,52);
    wire r_bp2 = inr(next_x,next_y,512,524,40,52);
    wire r_bp3 = inr(next_x,next_y,528,540,40,52);

    wire l_win1 = inr(next_x,next_y,270,282,16,28);
    wire l_win2 = inr(next_x,next_y,286,298,16,28);
    wire l_win3 = inr(next_x,next_y,302,314,16,28);
    wire r_win1 = inr(next_x,next_y,326,338,16,28);
    wire r_win2 = inr(next_x,next_y,342,354,16,28);
    wire r_win3 = inr(next_x,next_y,358,370,16,28);

    // No separate health bar in the spec-following version.
    wire hud_left_hp = 1'b0;
    wire hud_left_bp    = (l_bp1 && p1_bp_w >= 1) || (l_bp2 && p1_bp_w >= 2) || (l_bp3 && p1_bp_w >= 3);
    wire hud_right_bp   = (r_bp1 && p2_bp_w >= 1) || (r_bp2 && p2_bp_w >= 2) || (r_bp3 && p2_bp_w >= 3);
    wire hud_left_wins  = (l_win1 && p1_wins_w >= 1) || (l_win2 && p1_wins_w >= 2) || (l_win3 && p1_wins_w >= 3);
    wire hud_right_wins = (r_win1 && p2_wins_w >= 1) || (r_win2 && p2_wins_w >= 2) || (r_win3 && p2_wins_w >= 3);

    wire draw_left_name = draw_P(next_x,next_y,10'd16,10'd12) || (left_is_p1 ? draw_1(next_x,next_y,10'd48,10'd12) : left_is_p2 ? draw_2(next_x,next_y,10'd48,10'd12) : 1'b0);
    wire draw_right_name = draw_P(next_x,next_y,10'd567,10'd12) || (right_is_p1 ? draw_1(next_x,next_y,10'd599,10'd12) : right_is_p2 ? draw_2(next_x,next_y,10'd599,10'd12) : 1'b0);

    // Menu side selection labels
    wire menu_p1_left  = (p1_side_w == 2'd0) && (draw_P(next_x,next_y,10'd86,10'd190) || draw_1(next_x,next_y,10'd118,10'd190));
    wire menu_p1_mid   = (p1_side_w == 2'd2) && (draw_P(next_x,next_y,10'd286,10'd190) || draw_1(next_x,next_y,10'd318,10'd190));
    wire menu_p1_right = (p1_side_w == 2'd1) && (draw_P(next_x,next_y,10'd486,10'd190) || draw_1(next_x,next_y,10'd518,10'd190));
    wire menu_p2_left  = (p2_side_w == 2'd0) && (draw_P(next_x,next_y,10'd86,10'd242) || draw_2(next_x,next_y,10'd118,10'd242));
    wire menu_p2_mid   = (p2_side_w == 2'd2) && (draw_P(next_x,next_y,10'd286,10'd242) || draw_2(next_x,next_y,10'd318,10'd242));
    wire menu_p2_right = (p2_side_w == 2'd1) && (draw_P(next_x,next_y,10'd486,10'd242) || draw_2(next_x,next_y,10'd518,10'd242));
    wire menu_ready_to_start = (match_state_w == MATCH_MENU) && (p1_side_w != p2_side_w) && (p1_side_w != 2'd2) && (p2_side_w != 2'd2);
    wire draw_menu_start = menu_ready_to_start && blink_timer[5] && (draw_S(next_x,next_y,10'd248,10'd326) || draw_T(next_x,next_y,10'd283,10'd326) || draw_A(next_x,next_y,10'd318,10'd326) || draw_R(next_x,next_y,10'd353,10'd326) || draw_T(next_x,next_y,10'd388,10'd326));
    wire is_MENU_text = draw_M(next_x,next_y,10'd240,10'd28) || draw_E(next_x,next_y,10'd280,10'd28) ||
                        draw_N(next_x,next_y,10'd320,10'd28) || draw_U(next_x,next_y,10'd360,10'd28);

    // Center messages
    wire draw_count3 = (match_state_w == MATCH_COUNTDOWN) && (countdown_w < 8'd60)  && draw_3(next_x,next_y,10'd305,10'd110);
    wire draw_count2 = (match_state_w == MATCH_COUNTDOWN) && (countdown_w >= 8'd60)  && (countdown_w < 8'd120) && draw_2(next_x,next_y,10'd305,10'd110);
    wire draw_count1 = (match_state_w == MATCH_COUNTDOWN) && (countdown_w >= 8'd120) && (countdown_w < 8'd180) && draw_1(next_x,next_y,10'd305,10'd110);
    wire draw_start  = (match_state_w == MATCH_COUNTDOWN) && (countdown_w >= 8'd180) && msg_START(next_x,next_y);
    wire draw_KO     = (match_state_w == MATCH_KO)   && (draw_K(next_x,next_y,10'd275,10'd110) || draw_O(next_x,next_y,10'd315,10'd110));
    wire draw_DRAW   = (match_state_w == MATCH_DRAW) && msg_DRAW(next_x,next_y);

    // Screen game-over winner is controller-based, not side-based.
    // If P1 selected the right side and the right-side character wins, screen shows P1 WINS.
    wire gameover_winner = game_over && ((winner_is_ctrl_p1 && (draw_P(next_x,next_y,10'd220,10'd110) || draw_1(next_x,next_y,10'd250,10'd110))) ||
                                         (winner_is_ctrl_p2 && (draw_P(next_x,next_y,10'd220,10'd110) || draw_2(next_x,next_y,10'd250,10'd110))));
    wire gameover_wins = game_over && msg_WINS(next_x,next_y);
    wire gameover_text = game_over && blink_timer[5] && msg_GAMEOVER(next_x,next_y);

    wire debug_mode_text = SW[1] && blink_timer[5] && msg_DEBUGMODE(next_x,next_y);
    wire hit_text   = (match_state_w == MATCH_PLAYING) && (((p1_state_w == ST_HITSTUN) || (p2_state_w == ST_HITSTUN)) && blink_timer[2]) && msg_HIT(next_x,next_y);
    wire block_text = (match_state_w == MATCH_PLAYING) && (((p1_state_w == ST_BLOCKSTUN) || (p2_state_w == ST_BLOCKSTUN)) && blink_timer[2]) && msg_BLOCK(next_x,next_y);
    wire break_text = (match_state_w == MATCH_PLAYING) && (((p1_state_w == ST_GUARDBREAK) || (p2_state_w == ST_GUARDBREAK)) && blink_timer[2]) && msg_BREAK(next_x,next_y);

    wire left_charge_bg = (match_state_w == MATCH_PLAYING) && (left_charge_vis > 6'd0) && (next_x >= p1_x + 10'd14) && (next_x <= p1_x + 10'd50) && (next_y >= Y_START - 10'd14) && (next_y <= Y_START - 10'd8);
    wire left_charge_fg = left_charge_bg && (next_x <= p1_x + 10'd14 + left_charge_vis);
    wire right_charge_bg = (match_state_w == MATCH_PLAYING) && (right_charge_vis > 6'd0) && (next_x >= p2_x + 10'd14) && (next_x <= p2_x + 10'd50) && (next_y >= Y_START - 10'd14) && (next_y <= Y_START - 10'd8);
    wire right_charge_fg = right_charge_bg && (next_x >= p2_x + 10'd50 - right_charge_vis);

    // ---------------- Sprite / box geometry ----------------
    wire p1_in_box = (next_x >= p1_x) && (next_x < p1_x + BOX_W) && (next_y >= Y_START) && (next_y < Y_START + BOX_H);
    wire p2_in_box = (next_x >= p2_x) && (next_x < p2_x + BOX_W) && (next_y >= Y_START) && (next_y < Y_START + BOX_H);
    wire [9:0] p1_fx = next_x - p1_x;
    wire [9:0] p1_fy = next_y - Y_START;
    wire [9:0] p2_fx = (p2_x + BOX_W - 1'b1) - next_x;
    wire [9:0] p2_fy = next_y - Y_START;

    wire p1_body_pix = p1_in_box && sprite_body(p1_state_w, p1_fx, p1_fy, blink_timer[3]);
    wire p2_body_pix = p2_in_box && sprite_body(p2_state_w, p2_fx, p2_fy, blink_timer[3]);
    wire p1_fx_pix   = p1_in_box && sprite_fx(p1_state_w, p1_fx, p1_fy, blink_timer[3]);
    wire p2_fx_pix   = p2_in_box && sprite_fx(p2_state_w, p2_fx, p2_fy, blink_timer[3]);

    wire [9:0] p1_hurt_l = p1_x;
    wire [9:0] p1_hurt_r = ((p1_state_w == ST_ACTIVE) || (p1_state_w == ST_RECOVERY) || (p1_state_w == ST_SP_ACTIVE) || (p1_state_w == ST_SP_RECOVERY)) ?
                           (p1_x + BOX_W + ((p1_state_w == ST_SP_ACTIVE || p1_state_w == ST_SP_RECOVERY) ? 10'd80 : 10'd35)) :
                           (p1_x + BOX_W);
    wire [9:0] p2_hurt_l = ((p2_state_w == ST_ACTIVE) || (p2_state_w == ST_RECOVERY) || (p2_state_w == ST_SP_ACTIVE) || (p2_state_w == ST_SP_RECOVERY)) ?
                           (p2_x - ((p2_state_w == ST_SP_ACTIVE || p2_state_w == ST_SP_RECOVERY) ? 10'd80 : 10'd35)) :
                           p2_x;
    wire [9:0] p2_hurt_r = p2_x + BOX_W;

    wire p1_hurt_border = (next_x >= p1_hurt_l) && (next_x <= p1_hurt_r) && (next_y >= Y_START) && (next_y <= Y_START + BOX_H) &&
                          ((next_x <= p1_hurt_l + 1) || (next_x >= p1_hurt_r - 1) || (next_y <= Y_START + 1) || (next_y >= Y_START + BOX_H - 1));
    wire p2_hurt_border = (next_x >= p2_hurt_l) && (next_x <= p2_hurt_r) && (next_y >= Y_START) && (next_y <= Y_START + BOX_H) &&
                          ((next_x <= p2_hurt_l + 1) || (next_x >= p2_hurt_r - 1) || (next_y <= Y_START + 1) || (next_y >= Y_START + BOX_H - 1));

    wire [9:0] p1_hb_w = (p1_state_w == ST_SP_ACTIVE) ? 10'd80 : 10'd35;
    wire [9:0] p2_hb_w = (p2_state_w == ST_SP_ACTIVE) ? 10'd80 : 10'd35;
    wire p1_hitbox = ((p1_state_w == ST_ACTIVE) || (p1_state_w == ST_SP_ACTIVE)) &&
                     (next_x >= p1_x + BOX_W) && (next_x <= p1_x + BOX_W + p1_hb_w) &&
                     (next_y >= HITBOX_Y_START) && (next_y <= HITBOX_Y_START + ((p1_state_w == ST_SP_ACTIVE) ? 10'd52 : 10'd36));
    wire p2_hitbox = ((p2_state_w == ST_ACTIVE) || (p2_state_w == ST_SP_ACTIVE)) &&
                     (next_x >= p2_x - p2_hb_w) && (next_x <= p2_x) &&
                     (next_y >= HITBOX_Y_START) && (next_y <= HITBOX_Y_START + ((p2_state_w == ST_SP_ACTIVE) ? 10'd52 : 10'd36));
    wire p1_hitbox_border = p1_hitbox && ((next_x <= p1_x + BOX_W + 1) || (next_x >= p1_x + BOX_W + p1_hb_w - 1) || (next_y <= HITBOX_Y_START + 1) || (next_y >= HITBOX_Y_START + ((p1_state_w == ST_SP_ACTIVE) ? 10'd51 : 10'd35)));
    wire p2_hitbox_border = p2_hitbox && ((next_x <= p2_x - p2_hb_w + 1) || (next_x >= p2_x - 1) || (next_y <= HITBOX_Y_START + 1) || (next_y >= HITBOX_Y_START + ((p2_state_w == ST_SP_ACTIVE) ? 10'd51 : 10'd35)));

    wire p1_fireball = (p1_state_w == ST_SP_ACTIVE) &&
                       ((inr(next_x,next_y,p1_x+BOX_W+18,p1_x+BOX_W+48,HITBOX_Y_START+4,HITBOX_Y_START+36)) ||
                        (inr(next_x,next_y,p1_x+BOX_W+8,p1_x+BOX_W+58,HITBOX_Y_START+14,HITBOX_Y_START+26)) ||
                        (inr(next_x,next_y,p1_x+BOX_W+26,p1_x+BOX_W+38,HITBOX_Y_START-4,HITBOX_Y_START+44)));
    wire p1_fire_core = (p1_state_w == ST_SP_ACTIVE) && inr(next_x,next_y,p1_x+BOX_W+26,p1_x+BOX_W+42,HITBOX_Y_START+10,HITBOX_Y_START+30);

    wire p2_fireball = (p2_state_w == ST_SP_ACTIVE) &&
                       ((inr(next_x,next_y,p2_x-48,p2_x-18,HITBOX_Y_START+4,HITBOX_Y_START+36)) ||
                        (inr(next_x,next_y,p2_x-58,p2_x-8,HITBOX_Y_START+14,HITBOX_Y_START+26)) ||
                        (inr(next_x,next_y,p2_x-38,p2_x-26,HITBOX_Y_START-4,HITBOX_Y_START+44)));
    wire p2_fire_core = (p2_state_w == ST_SP_ACTIVE) && inr(next_x,next_y,p2_x-42,p2_x-26,HITBOX_Y_START+10,HITBOX_Y_START+30);

    wire p1_state_box = p1_in_box && ((p1_fx <= 1) || (p1_fx >= BOX_W-2) || (p1_fy <= 1) || (p1_fy >= BOX_H-2));
    wire p2_state_box = p2_in_box && ((p2_fx <= 1) || (p2_fx >= BOX_W-2) || (p2_fy <= 1) || (p2_fy >= BOX_H-2));

    reg [7:0] p1_fill_color, p2_fill_color, p1_state_color, p2_state_color;
    always @(*) begin
        p1_fill_color = 8'b101_101_11; // soft lavender
        p2_fill_color = 8'b101_110_10; // soft mint

        case (p1_state_w)
            ST_STARTUP:     p1_state_color = 8'b110_101_10;
            ST_ACTIVE:      p1_state_color = 8'b110_100_01;
            ST_RECOVERY:    p1_state_color = 8'b101_100_01;
            ST_HITSTUN:     p1_state_color = 8'b101_111_11;
            ST_BLOCKSTUN:   p1_state_color = 8'b111_111_10;
            ST_GUARDBREAK:  p1_state_color = 8'b111_111_01;
            ST_SP_STARTUP:  p1_state_color = 8'b110_101_11;
            ST_SP_ACTIVE:   p1_state_color = 8'b111_101_01;
            ST_SP_RECOVERY: p1_state_color = 8'b110_110_01;
            ST_MOVE_FWD:    p1_state_color = 8'b111_110_01;
            ST_MOVE_BACK:   p1_state_color = 8'b100_111_11;
            default:        p1_state_color = 8'b111_111_10;
        endcase

        case (p2_state_w)
            ST_STARTUP:     p2_state_color = 8'b110_101_10;
            ST_ACTIVE:      p2_state_color = 8'b110_100_01;
            ST_RECOVERY:    p2_state_color = 8'b101_100_01;
            ST_HITSTUN:     p2_state_color = 8'b101_111_11;
            ST_BLOCKSTUN:   p2_state_color = 8'b111_111_10;
            ST_GUARDBREAK:  p2_state_color = 8'b111_111_01;
            ST_SP_STARTUP:  p2_state_color = 8'b110_101_11;
            ST_SP_ACTIVE:   p2_state_color = 8'b111_101_01;
            ST_SP_RECOVERY: p2_state_color = 8'b110_110_01;
            ST_MOVE_FWD:    p2_state_color = 8'b111_110_01;
            ST_MOVE_BACK:   p2_state_color = 8'b100_111_11;
            default:        p2_state_color = 8'b111_111_10;
        endcase
    end

    // ---------------- Final render ----------------
    always @(*) begin
        current_color = bg_color;

        if (match_state_w == MATCH_MENU) begin
            if (is_MENU_text)
                current_color = 8'b111_111_11;
            else if (draw_menu_start)
                current_color = 8'b111_111_10;
            else if (menu_p1_left || menu_p1_mid || menu_p1_right)
                current_color = 8'b101_111_11;
            else if (menu_p2_left || menu_p2_mid || menu_p2_right)
                current_color = 8'b111_110_01;
            else if (debug_mode_text)
                current_color = 8'b111_111_11;
        end else begin
            if (debug_mode_text)
                current_color = 8'b111_111_11;
            else if (break_text)
                current_color = 8'b111_111_11;
            else if (block_text)
                current_color = 8'b111_111_11;
            else if (hit_text)
                current_color = 8'b111_111_11;
            else if (draw_count3 || draw_count2 || draw_count1 || draw_start)
                current_color = 8'b111_111_11;
            else if (draw_KO)
                current_color = 8'b111_111_11;
            else if (draw_DRAW)
                current_color = 8'b111_111_11;
            else if (gameover_winner || gameover_wins)
                current_color = 8'b111_111_11;
            else if (gameover_text)
                current_color = 8'b111_111_11;
            else if (draw_left_name || draw_right_name)
                current_color = 8'b111_111_11;
            else if (hud_left_bp || hud_right_bp)
                current_color = 8'b100_111_11;
            else if (hud_left_wins || hud_right_wins)
                current_color = 8'b111_111_10;
            else if (left_charge_fg || right_charge_fg)
                current_color = 8'b111_110_10;
            else if (left_charge_bg || right_charge_bg)
                current_color = 8'b100_100_10;
            else if (p1_fire_core || p2_fire_core)
                current_color = 8'b111_110_01;
            else if (p1_fireball || p2_fireball)
                current_color = 8'b111_100_01;
            else if (SW[1] && (p1_hurt_border || p2_hurt_border) && blink_timer[1])
                current_color = 8'b111_111_10;
            else if (SW[1] && (p1_hurt_border || p2_hurt_border))
                current_color = 8'b110_110_01;
            else if (SW[1] && p1_hitbox)
                current_color = p1_hitbox_border ? 8'b110_100_01 : (p1_state_w == ST_SP_ACTIVE ? 8'b111_101_01 : 8'b101_010_01);
            else if (SW[1] && p2_hitbox)
                current_color = p2_hitbox_border ? 8'b110_100_01 : (p2_state_w == ST_SP_ACTIVE ? 8'b111_101_01 : 8'b101_010_01);
            else if ((SW[1] && p1_state_box) || p1_fx_pix)
                current_color = p1_state_color;
            else if ((SW[1] && p2_state_box) || p2_fx_pix)
                current_color = p2_state_color;
            else if (p1_body_pix)
                current_color = p1_fill_color;
            else if (p2_body_pix)
                current_color = p2_fill_color;
        end
    end
endmodule


module debounce_signal(
    input  wire clk,
    input  wire rst,
    input  wire noisy,
    output reg  clean
);
    // About 10.5 ms at 25 MHz: enough for mechanical button/keypad bounce,
    // short enough not to feel laggy in a 60 Hz game.
    localparam integer CNTR_MAX = 18'd262143;

    reg stable_sample;
    reg [17:0] counter;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            clean <= 1'b0;
            stable_sample <= 1'b0;
            counter <= 18'd0;
        end else begin
            if (noisy == stable_sample) begin
                counter <= 18'd0;
            end else begin
                counter <= counter + 18'd1;
                if (counter == CNTR_MAX) begin
                    stable_sample <= noisy;
                    clean <= noisy;
                    counter <= 18'd0;
                end
            end
        end
    end
endmodule
