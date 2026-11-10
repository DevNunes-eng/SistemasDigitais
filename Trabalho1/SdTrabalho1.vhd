library IEEE;

use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- =========================================================================
-- BUTTON DEBOUNCER
-- =========================================================================

entity debauncer is
    port (
        -- Input signals
        clk       : in  STD_LOGIC; -- 50 MHz system clock
        rst       : in  STD_LOGIC; -- Synchronous reset
        btn_in    : in  STD_LOGIC; -- Raw push-button input

        -- Output signal
        btn_pulse : out STD_LOGIC  -- One-clock-cycle pulse
    );
end debauncer;

architecture Behavioral of debauncer is

    constant MAX_COUNT : integer := 1_000_000;

    signal sync       : std_logic_vector(1 downto 0) := (others => '0');
    signal btn_stable : std_logic := '0';
    signal btn_prev   : std_logic := '0';
    signal count      : integer range 0 to MAX_COUNT := 0;

begin

    -- 1 - Input synchronization using two flip-flops
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                sync <= (others => '0');
            else
                sync(0) <= btn_in;
                sync(1) <= sync(0);
            end if;
        end if;
    end process;

    -- 2 - Debouncing through a stability counter
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                count      <= 0;
                btn_stable <= '0';

            elsif sync(1) /= btn_stable then
                if count = MAX_COUNT then
                    btn_stable <= sync(1);
                    count      <= 0;
                else
                    count <= count + 1;
                end if;

            else
                -- Reset the counter whenever the input returns to its
                -- previously accepted state
                count <= 0;
            end if;
        end if;
    end process;

    -- 3 - Rising-edge detection
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                btn_prev  <= '0';
                btn_pulse <= '0';
            else
                btn_prev  <= btn_stable;
                btn_pulse <= btn_stable and (not btn_prev);
            end if;
        end if;
    end process;

end Behavioral;


-- =========================================================================
-- ALU
-- =========================================================================
library IEEE;

use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ULA is
    port (
        -- Input signals
        op      : in STD_LOGIC_VECTOR(2 downto 0);
        a       : in STD_LOGIC_VECTOR(3 downto 0);
        b       : in STD_LOGIC_VECTOR(3 downto 0);

        -- Output signals
        result  : out STD_LOGIC_VECTOR(3 downto 0);
        flag_z  : out STD_LOGIC;
        flag_n  : out STD_LOGIC;
        flag_c  : out STD_LOGIC;
        flag_ov : out STD_LOGIC
    );
end ULA;

architecture Behavioral of ULA is

    signal rest5 : STD_LOGIC_VECTOR(4 downto 0);

begin

    process(a, b, op)

        variable ext_a      : unsigned(4 downto 0);
        variable ext_b      : unsigned(4 downto 0);
        variable tempResult : unsigned(4 downto 0);
        variable shift_amt  : integer range 0 to 15;

    begin
        -- Extend both operands to five bits
        ext_a := unsigned('0' & a);
        ext_b := unsigned('0' & b);

        -- Default value for the temporary result
        tempResult := (others => '0');

        case op is

            -- Addition using 2's complement representation
            when "000" =>
                tempResult := ext_a + ext_b;

            -- Subtraction using the two's complement method
            when "001" =>
                tempResult := ext_a + (NOT ext_b) + to_unsigned(1, 5);

            -- Bitwise AND operation
            when "010" =>
                tempResult := '0' & (unsigned(a) AND unsigned(b));

            -- Bitwise OR operation
            when "011" =>
                tempResult := '0' & (unsigned(a) OR unsigned(b));

            -- Bitwise XOR operation
            when "100" =>
                tempResult := '0' & (unsigned(a) xor unsigned(b));

            -- Bitwise NOT operation
            when "101" =>
                tempResult := '0' & (not unsigned(a));

            ----------------------------------------------------------------
            -- Logical shift left
            -- The shifted-out bit is stored in bit 4 as the carry output.
            -- A = number to be shifted
            -- B = number of positions (controlled by shift_amt)
            ----------------------------------------------------------------
            when "110" =>

                shift_amt := to_integer(unsigned(b));

                case shift_amt is

                    when 0 =>
                        tempResult := '0' & unsigned(a);

                    when 1 =>
                        tempResult(4)          := a(3);
                        tempResult(3 downto 0) := unsigned(a(2 downto 0) & '0');

                    when 2 =>
                        tempResult(4)          := a(2);
                        tempResult(3 downto 0) := unsigned(a(1 downto 0) & STD_LOGIC_VECTOR'("00"));

                    when 3 =>
                        tempResult(4)          := a(1);
                        tempResult(3 downto 0) := unsigned(a(0) & STD_LOGIC_VECTOR'("000"));

                    when 4 =>
                        tempResult(4)          := a(0);
                        tempResult(3 downto 0) := (others => '0');

                    when others =>
                        tempResult := (others => '0');

                end case;

            ----------------------------------------------------------------
            -- Logical shift right
            -- The shifted-out bit is stored in bit 4 as the carry output.
            -- A = number to be shifted
            -- B = number of positions (controlled by shift_amt)
            ----------------------------------------------------------------
            when others =>
                shift_amt := to_integer(unsigned(b));

                case shift_amt is
                    when 0 =>
                        tempResult := '0' & unsigned(a);

                    when 1 =>
                        tempResult(4)          := a(0);
                        tempResult(3 downto 0) := unsigned('0' & a(3 downto 1));

                    when 2 =>
                        tempResult(4)          := a(1);
                        tempResult(3 downto 0) := unsigned(STD_LOGIC_VECTOR'("00") & a(3 downto 2));

                    when 3 =>
                        tempResult(4)          := a(2);
                        tempResult(3 downto 0) := unsigned(STD_LOGIC_VECTOR'("000") & a(3));

                    when 4 =>
                        tempResult(4)          := a(3);
                        tempResult(3 downto 0) := (others => '0');

                    when others =>
                        tempResult := (others => '0');

                end case;

        end case;

        rest5 <= std_logic_vector(tempResult);

    end process;

    -- OUTPUT
    result <= rest5(3 downto 0);

    -- Zero flag: asserted when all result bits are zero
    flag_z <= '1' when rest5(3 downto 0) = "0000" else '0';

    -- Negative flag: corresponds to the most significant result bit
    flag_n <= rest5(3);

    -- Carry flag: receives the fifth bit of the temporary result
    flag_c <= rest5(4);

    -- Overflow detection for arithmetic operations
    flag_ov <=
        ((NOT (a(3) XOR b(3))) AND (a(3) XOR rest5(3))) when op = "000"
    else
        ((a(3) XOR b(3)) AND (a(3) XOR rest5(3))) when op = "001"
    else
        '0';

end Behavioral;


-- =========================================================================
-- FSM CONTROLLER
-- =========================================================================
library IEEE;

use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity fsm_controller is
    port (
        clk       : in STD_LOGIC;
        rst       : in STD_LOGIC;
        btn_pulse : in STD_LOGIC;
        switches  : in STD_LOGIC_VECTOR(3 downto 0);

        out_op    : out STD_LOGIC_VECTOR(2 downto 0);
        out_a     : out STD_LOGIC_VECTOR(3 downto 0);
        out_b     : out STD_LOGIC_VECTOR(3 downto 0);
        state_out : out STD_LOGIC_VECTOR(1 downto 0)
    );
end fsm_controller;

architecture Behavioral of fsm_controller is

    -- Definition of the controller states
    type state_type is (S_WAIT_OP, S_WAIT_A, S_WAIT_B, S_COMPUTE);

    signal current_state : state_type := S_WAIT_OP;

    -- Registers used to store the selected operation and operands
    signal reg_op : STD_LOGIC_VECTOR(2 downto 0) := (others => '0');
    signal reg_a  : STD_LOGIC_VECTOR(3 downto 0) := (others => '0');
    signal reg_b  : STD_LOGIC_VECTOR(3 downto 0) := (others => '0');

begin

    process(clk)
    begin
        if rising_edge(clk) then

            if rst = '1' then

                current_state <= S_WAIT_OP;
                reg_op <= (others => '0');
                reg_a  <= (others => '0');
                reg_b  <= (others => '0');

            elsif btn_pulse = '1' then

                case current_state is
                    -- Capture the operation code
                    when S_WAIT_OP =>
                        reg_op <= switches(2 downto 0);
                        current_state <= S_WAIT_A;

                    -- Capture operand A
                    when S_WAIT_A =>
                        reg_a <= switches;
                        current_state <= S_WAIT_B;

                    -- Capture operand B
                    when S_WAIT_B =>
                        reg_b <= switches;
                        current_state <= S_COMPUTE;

                    -- Return to the initial state
                    when S_COMPUTE =>
                        current_state <= S_WAIT_OP;

                    -- Default state recovery
                    when others =>
                        current_state <= S_WAIT_OP;

                end case;

            end if;
        end if;
    end process;

    -- Connect internal registers to the ALU inputs
    out_op <= reg_op;
    out_a  <= reg_a;
    out_b  <= reg_b;

    -- Decoder for state LEDs
    with current_state select
        state_out <= "00" when S_WAIT_OP,
                     "01" when S_WAIT_A,
                     "10" when S_WAIT_B,
                     "11" when S_COMPUTE,
                     "00" when others;

end Behavioral;


-- =========================================================================
-- TOP LEVEL
-- =========================================================================
library IEEE;

use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity top_level is
    port (
        clk      : in STD_LOGIC;
        rst      : in STD_LOGIC;
        btn_in   : in STD_LOGIC;
        switches : in STD_LOGIC_VECTOR(3 downto 0);
        led      : out STD_LOGIC_VECTOR(7 downto 0)
    );
end top_level;

architecture Structural of top_level is

    -- Internal interconnection signals
    signal w_btn_pulse  : STD_LOGIC;
    signal w_op_code    : STD_LOGIC_VECTOR(2 downto 0);
    signal w_operando_a : STD_LOGIC_VECTOR(3 downto 0);
    signal w_operando_b : STD_LOGIC_VECTOR(3 downto 0);
    signal w_state_out  : STD_LOGIC_VECTOR(1 downto 0);

    signal w_result     : STD_LOGIC_VECTOR(3 downto 0);
    signal w_flag_zero  : STD_LOGIC;
    signal w_flag_neg   : STD_LOGIC;
    signal w_flag_carry : STD_LOGIC;
    signal w_flag_ovf   : STD_LOGIC;

begin

    -- Button debouncer instance
    U_DEB : entity work.debauncer
        port map (
            clk       => clk,
            rst       => rst,
            btn_in    => btn_in,
            btn_pulse => w_btn_pulse
        );

    -- FSM controller instance
    U_FSM : entity work.fsm_controller
        port map (
            clk       => clk,
            rst       => rst,
            btn_pulse => w_btn_pulse,
            switches  => switches,
            out_op    => w_op_code,
            out_a     => w_operando_a,
            out_b     => w_operando_b,
            state_out => w_state_out
        );

    -- ALU instance
    U_ALU : entity work.ULA
        port map (
            op      => w_op_code,
            a       => w_operando_a,
            b       => w_operando_b,
            result  => w_result,
            flag_z  => w_flag_zero,
            flag_n  => w_flag_neg,
            flag_c  => w_flag_carry,
            flag_ov => w_flag_ovf
        );

    -- LED output selection
    p_led_mux : process(w_state_out, w_result,
                        w_flag_zero, w_flag_neg, w_flag_carry, w_flag_ovf)
    begin
        if w_state_out = "11" then
            -- Output state: display the ALU result and flags
            led(3 downto 0) <= w_result;
            led(4)          <= w_flag_zero;
            led(5)          <= w_flag_neg;
            led(6)          <= w_flag_carry;
            led(7)          <= w_flag_ovf;

        else
            -- Input states: display the current FSM state
            led(1 downto 0) <= w_state_out;
            led(7 downto 2) <= (others => '0');

        end if;

    end process p_led_mux;

end Structural;