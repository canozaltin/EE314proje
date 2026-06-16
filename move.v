module move(
    deneme
    input  wire clk,
    input  wire rst,

    input  wire p1_left,
    input  wire p1_right,
    input  wire p1_attack,

    input  wire p2_left,
    input  wire p2_right,
    input  wire p2_attack,

    output reg  [9:0] p1_pos_x,
    output reg  [9:0] p2_pos_x,
    output reg  [3:0] p1_state,
    output reg  [3:0] p2_state,
    output reg  [1:0] p1_hp,  // compatibility output; only 0 means KO, not a 3-hit health bar
    output reg  [1:0] p2_hp,  // compatibility output; only 0 means KO, not a 3-hit health bar
    output reg  [1:0] p1_bp,
    output reg  [1:0] p2_bp,
    output reg  [2:0] match_state,
    output reg  [7:0] countdown_timer,
    output reg  [1:0] p1_wins,
    output reg  [1:0] p2_wins,
    output reg  [1:0] p1_side,
    output reg  [1:0] p2_side
);

    parameter BOX_WIDTH       = 64;
    parameter SCREEN_W        = 640;
    parameter P1_START_X      = 50;
    parameter P2_START_X      = 640 - 50 - BOX_WIDTH;

    parameter FORWARD_STEP    = 3;
    parameter BACK_STEP       = 2;
    parameter SP_FORWARD_STEP = 28;   // 56 px total over 2 active frames
    parameter HITBOX_W        = 35;
    parameter SP_HITBOX_W     = 80;
    parameter SP_CHARGE_MAX   = 36;   // 0.6 s at 60 Hz

    localparam [3:0] ST_IDLE        = 4'd0;
    localparam [3:0] ST_STARTUP     = 4'd1;
    localparam [3:0] ST_ACTIVE      = 4'd2;
    localparam [3:0] ST_RECOVERY    = 4'd3;
    localparam [3:0] ST_HITSTUN     = 4'd4;
    localparam [3:0] ST_BLOCKSTUN   = 4'd5;
    localparam [3:0] ST_GUARDBREAK  = 4'd6;
    localparam [3:0] ST_SP_STARTUP  = 4'd7;
    localparam [3:0] ST_SP_ACTIVE   = 4'd8;
    localparam [3:0] ST_SP_RECOVERY = 4'd9;
    localparam [3:0] ST_MOVE_FWD    = 4'd10;
    localparam [3:0] ST_MOVE_BACK   = 4'd11;

    localparam [2:0] MATCH_MENU      = 3'd0;
    localparam [2:0] MATCH_COUNTDOWN = 3'd1;
    localparam [2:0] MATCH_PLAYING   = 3'd2;
    localparam [2:0] MATCH_KO        = 3'd3;
    localparam [2:0] MATCH_GAMEOVER  = 3'd4;
    localparam [2:0] MATCH_DRAW      = 3'd5;

    // Frame data
    localparam N_STARTUP   = 5;
    localparam N_ACTIVE    = 2;
    localparam N_RECOVERY  = 17;

    localparam S_STARTUP   = 14;
    localparam S_ACTIVE    = 2;
    localparam S_RECOVERY  = 31;

    // Recovery table implementation when hit connects on first active frame.
    // Basic attacker remaining frames = 1 + 17 = 18
    localparam [7:0] B_HITSTUN   = 8'd17; // -1
    localparam [7:0] B_BLOCKSTUN = 8'd15; // -3
    localparam [7:0] B_GBSTUN    = 8'd35; // +17

    // Special attacker remaining frames = 1 + 31 = 32
    localparam [7:0] S_BLOCKSTUN = 8'd20; // -12
    localparam [7:0] S_GBSTUN    = 8'd35; // +3

    reg [7:0] p1_timer, p2_timer;
    reg [7:0] p1_stun_limit, p2_stun_limit;
    reg [7:0] p1_charge, p2_charge;
    reg       p1_hit_success, p2_hit_success;
    reg       p1_has_hit, p2_has_hit;
    reg [7:0] ko_timer;

    reg p1_atk_prev_menu;
    reg c1_atk_prev, c2_atk_prev;
    reg p1_any_prev;

    wire p1_any      = p1_left || p1_right || p1_attack;
    wire p1_any_edge = p1_any && !p1_any_prev;
    wire p1_atk_edge_menu = p1_attack && !p1_atk_prev_menu;

    // Controller-to-side mapping.
    // Internal character 1 is always the LEFT-side character.
    // Internal character 2 is always the RIGHT-side character.
    wire c1_left   = (p1_side == 2'd0) ? p1_left   : (p2_side == 2'd0) ? p2_left   : 1'b0;
    wire c1_right  = (p1_side == 2'd0) ? p1_right  : (p2_side == 2'd0) ? p2_right  : 1'b0;
    wire c1_attack = (p1_side == 2'd0) ? p1_attack : (p2_side == 2'd0) ? p2_attack : 1'b0;

    wire c2_left   = (p1_side == 2'd1) ? p1_left   : (p2_side == 2'd1) ? p2_left   : 1'b0;
    wire c2_right  = (p1_side == 2'd1) ? p1_right  : (p2_side == 2'd1) ? p2_right  : 1'b0;
    wire c2_attack = (p1_side == 2'd1) ? p1_attack : (p2_side == 2'd1) ? p2_attack : 1'b0;

    wire c1_atk_edge = c1_attack && !c1_atk_prev;
    wire c2_atk_edge = c2_attack && !c2_atk_prev;
    // Hold-and-release special only fires when the internal charge reached SP_CHARGE_MAX.
    // Releasing early falls back to no special; this is what makes the charge bar meaningful.
    wire c1_charge_release = c1_atk_prev && !c1_attack && (p1_charge >= SP_CHARGE_MAX);
    wire c2_charge_release = c2_atk_prev && !c2_attack && (p2_charge >= SP_CHARGE_MAX);

    wire p1_is_active = (p1_state == ST_ACTIVE) || (p1_state == ST_SP_ACTIVE);
    wire p2_is_active = (p2_state == ST_ACTIVE) || (p2_state == ST_SP_ACTIVE);

    wire p1_is_extended = p1_is_active || (p1_state == ST_RECOVERY) || (p1_state == ST_SP_RECOVERY);
    wire p2_is_extended = p2_is_active || (p2_state == ST_RECOVERY) || (p2_state == ST_SP_RECOVERY);

    wire [9:0] p1_cur_hb_w = (p1_state == ST_SP_ACTIVE) ? SP_HITBOX_W : HITBOX_W;
    wire [9:0] p2_cur_hb_w = (p2_state == ST_SP_ACTIVE) ? SP_HITBOX_W : HITBOX_W;

    // Hitboxes
    wire [9:0] p1_hb_l = p1_pos_x + BOX_WIDTH;
    wire [9:0] p1_hb_r = p1_pos_x + BOX_WIDTH + p1_cur_hb_w;
    wire [9:0] p2_hb_l = p2_pos_x - p2_cur_hb_w;
    wire [9:0] p2_hb_r = p2_pos_x;

    // Hurtboxes extend during active/recovery so whiff punish is possible.
    wire [9:0] p1_hurt_l = p1_pos_x;
    wire [9:0] p1_hurt_r = p1_is_extended ? (p1_pos_x + BOX_WIDTH + p1_cur_hb_w) : (p1_pos_x + BOX_WIDTH);
    wire [9:0] p2_hurt_l = p2_is_extended ? (p2_pos_x - p2_cur_hb_w) : p2_pos_x;
    wire [9:0] p2_hurt_r = p2_pos_x + BOX_WIDTH;

    wire p1_hit_cond = p1_is_active && !p1_has_hit && (p1_hb_l <= p2_hurt_r) && (p1_hb_r >= p2_hurt_l);
    wire p2_hit_cond = p2_is_active && !p2_has_hit && (p2_hb_l <= p1_hurt_r) && (p2_hb_r >= p1_hurt_l);

    wire sim_hit = p1_hit_cond && p2_hit_cond;
    wire p1_forced_transition = sim_hit || p2_hit_cond;
    wire p2_forced_transition = sim_hit || p1_hit_cond;

    // Deterministic blocking: pressing both directions is neutral, not block.
    wire p1_can_block = (p1_state == ST_IDLE) || (p1_state == ST_MOVE_BACK);
    wire p2_can_block = (p2_state == ST_IDLE) || (p2_state == ST_MOVE_BACK);
    wire p1_blocking  = p1_can_block && c1_left  && !c1_right;
    wire p2_blocking  = p2_can_block && c2_right && !c2_left;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            p1_pos_x <= P1_START_X;
            p2_pos_x <= P2_START_X;
            p1_state <= ST_IDLE;
            p2_state <= ST_IDLE;
            p1_hp <= 2'd3;
            p2_hp <= 2'd3;
            p1_bp <= 2'd3;
            p2_bp <= 2'd3;
            p1_wins <= 2'd0;
            p2_wins <= 2'd0;
            countdown_timer <= 8'd0;
            p1_charge <= 8'd0;
            p2_charge <= 8'd0;
            p1_timer <= 8'd0;
            p2_timer <= 8'd0;
            p1_stun_limit <= 8'd0;
            p2_stun_limit <= 8'd0;
            p1_hit_success <= 1'b0;
            p2_hit_success <= 1'b0;
            p1_has_hit <= 1'b0;
            p2_has_hit <= 1'b0;
            ko_timer <= 8'd0;
            match_state <= MATCH_MENU;
            p1_side <= 2'd2;
            p2_side <= 2'd2;
            p1_atk_prev_menu <= 1'b0;
            c1_atk_prev <= 1'b0;
            c2_atk_prev <= 1'b0;
            p1_any_prev <= 1'b0;
        end else begin
            p1_atk_prev_menu <= p1_attack;
            c1_atk_prev <= c1_attack;
            c2_atk_prev <= c2_attack;
            p1_any_prev <= p1_any;

            if (match_state == MATCH_MENU) begin
                if (p1_left && !p1_right)
                    p1_side <= 2'd0;
                else if (p1_right && !p1_left)
                    p1_side <= 2'd1;

                if (p2_left && !p2_right)
                    p2_side <= 2'd0;
                else if (p2_right && !p2_left)
                    p2_side <= 2'd1;

                if (p1_atk_edge_menu && (p1_side != p2_side) && (p1_side != 2'd2) && (p2_side != 2'd2)) begin
                    match_state <= MATCH_COUNTDOWN;
                    countdown_timer <= 8'd0;
                    p1_pos_x <= P1_START_X;
                    p2_pos_x <= P2_START_X;
                    p1_state <= ST_IDLE;
                    p2_state <= ST_IDLE;
                    p1_hp <= 2'd3;
                    p2_hp <= 2'd3;
                    p1_bp <= 2'd3;
                    p2_bp <= 2'd3;
                    p1_charge <= 8'd0;
                    p2_charge <= 8'd0;
                    p1_timer <= 8'd0;
                    p2_timer <= 8'd0;
                    p1_stun_limit <= 8'd0;
                    p2_stun_limit <= 8'd0;
                    p1_hit_success <= 1'b0;
                    p2_hit_success <= 1'b0;
                    p1_has_hit <= 1'b0;
                    p2_has_hit <= 1'b0;
                end
            end else if (match_state == MATCH_COUNTDOWN) begin
                if (countdown_timer < 8'd240)
                    countdown_timer <= countdown_timer + 8'd1;
                else begin
                    match_state <= MATCH_PLAYING;
                    countdown_timer <= 8'd0;
                end
            end else if (match_state == MATCH_PLAYING) begin
                // Bookkeeping for hold-and-release special. Basic attacks now start on press,
                // but the same attack button can still be held and released after SP_CHARGE_MAX
                // to start a special attack once the character reaches a cancellable/neutral state.
                if (c1_attack) begin
                    if (p1_charge < SP_CHARGE_MAX)
                        p1_charge <= p1_charge + 8'd1;
                end else if (c1_atk_prev) begin
                    p1_charge <= 8'd0;
                end

                if (c2_attack) begin
                    if (p2_charge < SP_CHARGE_MAX)
                        p2_charge <= p2_charge + 8'd1;
                end else if (c2_atk_prev) begin
                    p2_charge <= 8'd0;
                end

                // Resolve clashes/hits first.
                if (sim_hit) begin
                    p1_has_hit <= 1'b1;
                    p2_has_hit <= 1'b1;

                    // Edge cases:
                    // - both specials connect on the same frame: DRAW round, no one gets a win.
                    // - both normal attacks connect on the same frame: both lose 1 HP and enter hitstun.
                    // - special vs normal on the same frame: special still causes KO, while the special user
                    //   can also take the normal hit before the round resolves.
                    if ((p1_state == ST_SP_ACTIVE) && (p2_state == ST_SP_ACTIVE)) begin
                        match_state <= MATCH_DRAW;
                        ko_timer <= 8'd0;
                    end else begin
                        p1_state <= ST_HITSTUN;
                        p2_state <= ST_HITSTUN;
                        p1_timer <= 8'd0;
                        p2_timer <= 8'd0;
                        p1_stun_limit <= B_HITSTUN;
                        p2_stun_limit <= B_HITSTUN;

                        if (p1_bp > 0) p1_bp <= p1_bp - 2'd1;
                        if (p2_bp > 0) p2_bp <= p2_bp - 2'd1;

                        // No normal health system: basic simultaneous hits only cause
                        // hitstun and BP loss. A simultaneous special still creates a KO flag,
                        // except the both-specials case above is handled as DRAW.
                        if (p2_state == ST_SP_ACTIVE)
                            p1_hp <= 2'd0;

                        if (p1_state == ST_SP_ACTIVE)
                            p2_hp <= 2'd0;
                    end
                end else begin
                    if (p1_hit_cond) begin
                        p1_has_hit <= 1'b1;
                        p1_hit_success <= 1'b1;

                        if (p2_blocking) begin
                            if (p2_bp > 0) begin
                                p2_state <= ST_BLOCKSTUN;
                                p2_timer <= 8'd0;
                                p2_stun_limit <= (p1_state == ST_SP_ACTIVE) ? S_BLOCKSTUN : B_BLOCKSTUN;
                                p2_bp <= p2_bp - 2'd1;
                            end else begin
                                p2_state <= ST_GUARDBREAK;
                                p2_timer <= 8'd0;
                                p2_stun_limit <= (p1_state == ST_SP_ACTIVE) ? S_GBSTUN : B_GBSTUN;

                                // BP is already zero: blocked attack becomes GUARD BREAK only.
                                // Per the project text, KO happens only when special is not blocked.
                            end
                        end else begin
                            p2_state <= ST_HITSTUN;
                            p2_timer <= 8'd0;
                            p2_stun_limit <= B_HITSTUN;
                            if (p2_bp > 0) p2_bp <= p2_bp - 2'd1;
                            // Basic hit: HITSTUN + BP loss only. Special hit: KO.
                            if (p1_state == ST_SP_ACTIVE)
                                p2_hp <= 2'd0;
                        end
                    end else if (p2_hit_cond) begin
                        p2_has_hit <= 1'b1;
                        p2_hit_success <= 1'b1;

                        if (p1_blocking) begin
                            if (p1_bp > 0) begin
                                p1_state <= ST_BLOCKSTUN;
                                p1_timer <= 8'd0;
                                p1_stun_limit <= (p2_state == ST_SP_ACTIVE) ? S_BLOCKSTUN : B_BLOCKSTUN;
                                p1_bp <= p1_bp - 2'd1;
                            end else begin
                                p1_state <= ST_GUARDBREAK;
                                p1_timer <= 8'd0;
                                p1_stun_limit <= (p2_state == ST_SP_ACTIVE) ? S_GBSTUN : B_GBSTUN;

                                // BP is already zero: blocked attack becomes GUARD BREAK only.
                                // Per the project text, KO happens only when special is not blocked.
                            end
                        end else begin
                            p1_state <= ST_HITSTUN;
                            p1_timer <= 8'd0;
                            p1_stun_limit <= B_HITSTUN;
                            if (p1_bp > 0) p1_bp <= p1_bp - 2'd1;
                            // Basic hit: HITSTUN + BP loss only. Special hit: KO.
                            if (p2_state == ST_SP_ACTIVE)
                                p1_hp <= 2'd0;
                        end
                    end
                end

                if (!p1_forced_transition) begin
                    case (p1_state)
                        ST_IDLE, ST_MOVE_FWD, ST_MOVE_BACK: begin
                            p1_hit_success <= 1'b0;
                            p1_has_hit <= 1'b0;

                            if (c1_charge_release) begin
                                p1_state <= ST_SP_STARTUP;
                                p1_timer <= 8'd0;
                                p1_charge <= 8'd0;
                            end else if (c1_atk_edge) begin
                                // Basic attack starts immediately on press edge.
                                p1_state <= ST_STARTUP;
                                p1_timer <= 8'd0;
                            end else begin
                                if (c1_left && !c1_right) begin
                                    if (p1_pos_x >= BACK_STEP)
                                        p1_pos_x <= p1_pos_x - BACK_STEP;
                                    p1_state <= ST_MOVE_BACK;
                                end else if (c1_right && !c1_left) begin
                                    if (p1_pos_x < (p2_pos_x - BOX_WIDTH - FORWARD_STEP))
                                        p1_pos_x <= p1_pos_x + FORWARD_STEP;
                                    p1_state <= ST_MOVE_FWD;
                                end else begin
                                    p1_state <= ST_IDLE;
                                end
                            end
                        end

                        ST_STARTUP: begin
                            if (p1_timer == N_STARTUP-1) begin
                                p1_state <= ST_ACTIVE;
                                p1_timer <= 8'd0;
                            end else p1_timer <= p1_timer + 8'd1;
                        end

                        ST_ACTIVE: begin
                            if (p1_timer == N_ACTIVE-1) begin
                                p1_state <= ST_RECOVERY;
                                p1_timer <= 8'd0;
                            end else p1_timer <= p1_timer + 8'd1;
                        end

                        ST_RECOVERY: begin
                            // Cancel into special after a successful, non-whiffed basic attack.
                            // This requires a new attack press during recovery, matching the spec.
                            if (p1_hit_success && c1_atk_edge) begin
                                p1_state <= ST_SP_STARTUP;
                                p1_timer <= 8'd0;
                                p1_hit_success <= 1'b0;
                                p1_has_hit <= 1'b0;
                                p1_charge <= 8'd0;
                            end else if (c1_charge_release) begin
                                p1_state <= ST_SP_STARTUP;
                                p1_timer <= 8'd0;
                                p1_has_hit <= 1'b0;
                                p1_charge <= 8'd0;
                            end else if (p1_timer == N_RECOVERY-1) begin
                                p1_state <= ST_IDLE;
                                p1_timer <= 8'd0;
                            end else p1_timer <= p1_timer + 8'd1;
                        end

                        ST_SP_STARTUP: begin
                            if (p1_timer == S_STARTUP-1) begin
                                p1_state <= ST_SP_ACTIVE;
                                p1_timer <= 8'd0;
                            end else p1_timer <= p1_timer + 8'd1;
                        end

                        ST_SP_ACTIVE: begin
                            if (p1_pos_x < (p2_pos_x - BOX_WIDTH - SP_FORWARD_STEP))
                                p1_pos_x <= p1_pos_x + SP_FORWARD_STEP;
                            if (p1_timer == S_ACTIVE-1) begin
                                p1_state <= ST_SP_RECOVERY;
                                p1_timer <= 8'd0;
                            end else p1_timer <= p1_timer + 8'd1;
                        end

                        ST_SP_RECOVERY: begin
                            if (p1_timer == S_RECOVERY-1) begin
                                p1_state <= ST_IDLE;
                                p1_timer <= 8'd0;
                            end else p1_timer <= p1_timer + 8'd1;
                        end

                        ST_HITSTUN, ST_BLOCKSTUN, ST_GUARDBREAK: begin
                            if ((p1_stun_limit == 8'd0) || (p1_timer >= p1_stun_limit - 8'd1)) begin
                                p1_state <= ST_IDLE;
                                p1_timer <= 8'd0;
                                p1_stun_limit <= 8'd0;
                            end else p1_timer <= p1_timer + 8'd1;
                        end

                        default: p1_state <= ST_IDLE;
                    endcase
                end

                if (!p2_forced_transition) begin
                    case (p2_state)
                        ST_IDLE, ST_MOVE_FWD, ST_MOVE_BACK: begin
                            p2_hit_success <= 1'b0;
                            p2_has_hit <= 1'b0;

                            if (c2_charge_release) begin
                                p2_state <= ST_SP_STARTUP;
                                p2_timer <= 8'd0;
                                p2_charge <= 8'd0;
                            end else if (c2_atk_edge) begin
                                // Basic attack starts immediately on press edge.
                                p2_state <= ST_STARTUP;
                                p2_timer <= 8'd0;
                            end else begin
                                if (c2_right && !c2_left) begin
                                    if (p2_pos_x <= (SCREEN_W - 1 - BOX_WIDTH - BACK_STEP))
                                        p2_pos_x <= p2_pos_x + BACK_STEP;
                                    p2_state <= ST_MOVE_BACK;
                                end else if (c2_left && !c2_right) begin
                                    if (p2_pos_x > (p1_pos_x + BOX_WIDTH + FORWARD_STEP))
                                        p2_pos_x <= p2_pos_x - FORWARD_STEP;
                                    p2_state <= ST_MOVE_FWD;
                                end else begin
                                    p2_state <= ST_IDLE;
                                end
                            end
                        end

                        ST_STARTUP: begin
                            if (p2_timer == N_STARTUP-1) begin
                                p2_state <= ST_ACTIVE;
                                p2_timer <= 8'd0;
                            end else p2_timer <= p2_timer + 8'd1;
                        end

                        ST_ACTIVE: begin
                            if (p2_timer == N_ACTIVE-1) begin
                                p2_state <= ST_RECOVERY;
                                p2_timer <= 8'd0;
                            end else p2_timer <= p2_timer + 8'd1;
                        end

                        ST_RECOVERY: begin
                            // Cancel into special after a successful, non-whiffed basic attack.
                            if (p2_hit_success && c2_atk_edge) begin
                                p2_state <= ST_SP_STARTUP;
                                p2_timer <= 8'd0;
                                p2_hit_success <= 1'b0;
                                p2_has_hit <= 1'b0;
                                p2_charge <= 8'd0;
                            end else if (c2_charge_release) begin
                                p2_state <= ST_SP_STARTUP;
                                p2_timer <= 8'd0;
                                p2_has_hit <= 1'b0;
                                p2_charge <= 8'd0;
                            end else if (p2_timer == N_RECOVERY-1) begin
                                p2_state <= ST_IDLE;
                                p2_timer <= 8'd0;
                            end else p2_timer <= p2_timer + 8'd1;
                        end

                        ST_SP_STARTUP: begin
                            if (p2_timer == S_STARTUP-1) begin
                                p2_state <= ST_SP_ACTIVE;
                                p2_timer <= 8'd0;
                            end else p2_timer <= p2_timer + 8'd1;
                        end

                        ST_SP_ACTIVE: begin
                            if (p2_pos_x > (p1_pos_x + BOX_WIDTH + SP_FORWARD_STEP))
                                p2_pos_x <= p2_pos_x - SP_FORWARD_STEP;
                            if (p2_timer == S_ACTIVE-1) begin
                                p2_state <= ST_SP_RECOVERY;
                                p2_timer <= 8'd0;
                            end else p2_timer <= p2_timer + 8'd1;
                        end

                        ST_SP_RECOVERY: begin
                            if (p2_timer == S_RECOVERY-1) begin
                                p2_state <= ST_IDLE;
                                p2_timer <= 8'd0;
                            end else p2_timer <= p2_timer + 8'd1;
                        end

                        ST_HITSTUN, ST_BLOCKSTUN, ST_GUARDBREAK: begin
                            if ((p2_stun_limit == 8'd0) || (p2_timer >= p2_stun_limit - 8'd1)) begin
                                p2_state <= ST_IDLE;
                                p2_timer <= 8'd0;
                                p2_stun_limit <= 8'd0;
                            end else p2_timer <= p2_timer + 8'd1;
                        end

                        default: p2_state <= ST_IDLE;
                    endcase
                end

                // Round resolution: p*_hp is used only as a KO latch.
                // It is set to 0 only by an unblocked special attack. Basic attacks never win rounds.
                if ((p1_hp == 0) && (p2_hp == 0)) begin
                    match_state <= MATCH_DRAW;
                    ko_timer <= 8'd0;
                end else if (p1_hp == 0 || p2_hp == 0) begin
                    match_state <= MATCH_KO;
                    ko_timer <= 8'd0;
                    if (p1_hp == 0 && p2_hp > 0)
                        p2_wins <= p2_wins + 2'd1;
                    if (p2_hp == 0 && p1_hp > 0)
                        p1_wins <= p1_wins + 2'd1;
                end
            end else if ((match_state == MATCH_KO) || (match_state == MATCH_DRAW)) begin
                if (ko_timer < 8'd120)
                    ko_timer <= ko_timer + 8'd1;
                else begin
                    if (p1_wins == 2'd3 || p2_wins == 2'd3)
                        match_state <= MATCH_GAMEOVER;
                    else begin
                        p1_pos_x <= P1_START_X;
                        p2_pos_x <= P2_START_X;
                        p1_state <= ST_IDLE;
                        p2_state <= ST_IDLE;
                        p1_hp <= 2'd3;
                        p2_hp <= 2'd3;
                        p1_bp <= 2'd3;
                        p2_bp <= 2'd3;
                        p1_charge <= 8'd0;
                        p2_charge <= 8'd0;
                        p1_timer <= 8'd0;
                        p2_timer <= 8'd0;
                        p1_stun_limit <= 8'd0;
                        p2_stun_limit <= 8'd0;
                        p1_hit_success <= 1'b0;
                        p2_hit_success <= 1'b0;
                        p1_has_hit <= 1'b0;
                        p2_has_hit <= 1'b0;
                        match_state <= MATCH_COUNTDOWN;
                        countdown_timer <= 8'd0;
                    end
                end
            end else if (match_state == MATCH_GAMEOVER) begin
                if (p1_any_edge) begin
                    p1_wins <= 2'd0;
                    p2_wins <= 2'd0;
                    p1_pos_x <= P1_START_X;
                    p2_pos_x <= P2_START_X;
                    p1_hp <= 2'd3;
                    p2_hp <= 2'd3;
                    p1_bp <= 2'd3;
                    p2_bp <= 2'd3;
                    p1_state <= ST_IDLE;
                    p2_state <= ST_IDLE;
                    p1_charge <= 8'd0;
                    p2_charge <= 8'd0;
                    p1_timer <= 8'd0;
                    p2_timer <= 8'd0;
                    p1_stun_limit <= 8'd0;
                    p2_stun_limit <= 8'd0;
                    p1_hit_success <= 1'b0;
                    p2_hit_success <= 1'b0;
                    p1_has_hit <= 1'b0;
                    p2_has_hit <= 1'b0;
                    match_state <= MATCH_MENU;
                end
            end
        end
    end
endmodule
