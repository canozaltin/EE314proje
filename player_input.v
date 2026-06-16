module player_input(
    input wire game_clk,
    input wire reset,

    input wire gpio_left,
    input wire gpio_right,
    input wire gpio_attack,

    output reg left,
    output reg right,
    output reg attack
);

always @(posedge game_clk or posedge reset)
begin
    if(reset)
    begin
        left   <= 1'b0;
        right  <= 1'b0;
        attack <= 1'b0;
    end
    else
    begin
        // Active-low GPIO/button lines.
        left   <= ~gpio_left;
        right  <= ~gpio_right;
        attack <= ~gpio_attack;
    end
end

endmodule

