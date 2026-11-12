-- =========================================================================
-- HANGMAN GAME (FORCA) - SPARTAN-3A STARTER KIT (XC3S700A-4FG484)
--
-- Inputs : PS/2 keyboard (letters A-Z and ENTER), BTN_EAST (reset),
--          BTN_WEST (optional ENTER), switches (optional word selection)
-- Outputs: 16x2 character LCD (4-bit mode) and 8 LEDs
--
-- Everything is inside ONE entity and ONE architecture. Each section of the
-- architecture is an independent process, so the game FSM never waits for
-- the PS/2 receiver or for the LCD controller.
-- =========================================================================

-- =========================================================================
-- 1. LIBRARIES AND ENTITY
-- =========================================================================
library IEEE;

use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity hangman is
    generic (
        SIM_FAST : boolean := false -- true ONLY in the testbench: shortens the long waits (20 ms, 5 ms...)
    );
    port (
        -- INPUT
        clk         : in  STD_LOGIC;                      -- 50 MHz board clock (20 ns period)
        rst         : in  STD_LOGIC;                      -- BTN_EAST, active high (debounced inside)
        btn_in      : in  STD_LOGIC;                      -- BTN_WEST, works as an extra ENTER key
        switches    : in  STD_LOGIC_VECTOR(3 downto 0);   -- "0000" = random word, otherwise fixed word (test mode)
        ps2_clk     : in  STD_LOGIC;                      -- PS/2 clock coming from the keyboard
        ps2_data    : in  STD_LOGIC;                      -- PS/2 data coming from the keyboard

        -- OUTPUT
        lcd_e       : out STD_LOGIC;                      -- LCD enable pulse
        lcd_rs      : out STD_LOGIC;                      -- LCD register select (0 = command, 1 = data)
        lcd_rw      : out STD_LOGIC;                      -- LCD read/write (always '0' = write)
        lcd_db      : out STD_LOGIC_VECTOR(7 downto 4);   -- LCD data bus, 4-bit mode uses only DB7..DB4
        led         : out STD_LOGIC_VECTOR(7 downto 0)    -- 8 status LEDs
    );
end hangman;

architecture Behavioral of hangman is

    -- =====================================================================
    -- 2. CONSTANTS AND TYPES
    -- =====================================================================

    -- Helper used only for constants: picks the fast value when simulating
    function sel_int (cond : boolean; a : integer; b : integer) return integer is
    begin
        if cond then
            return a;
        else
            return b;
        end if;
    end function;

    -- Converts a VHDL character to its 8-bit ASCII code
    function chr (c : character) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(character'pos(c), 8));
    end function;

    -- PS/2 scan code (set 2, make code) -> ASCII. Returns x"00" if the key is not used
    function scan_to_ascii (sc : std_logic_vector(7 downto 0)) return std_logic_vector is
    begin
        case sc is
            when x"1C" => return x"41"; -- A
            when x"32" => return x"42"; -- B
            when x"21" => return x"43"; -- C
            when x"23" => return x"44"; -- D
            when x"24" => return x"45"; -- E
            when x"2B" => return x"46"; -- F
            when x"34" => return x"47"; -- G
            when x"33" => return x"48"; -- H
            when x"43" => return x"49"; -- I
            when x"3B" => return x"4A"; -- J
            when x"42" => return x"4B"; -- K
            when x"4B" => return x"4C"; -- L
            when x"3A" => return x"4D"; -- M
            when x"31" => return x"4E"; -- N
            when x"44" => return x"4F"; -- O
            when x"4D" => return x"50"; -- P
            when x"15" => return x"51"; -- Q
            when x"2D" => return x"52"; -- R
            when x"1B" => return x"53"; -- S
            when x"2C" => return x"54"; -- T
            when x"3C" => return x"55"; -- U
            when x"2A" => return x"56"; -- V
            when x"1D" => return x"57"; -- W
            when x"22" => return x"58"; -- X
            when x"35" => return x"59"; -- Y
            when x"1A" => return x"5A"; -- Z
            when x"5A" => return x"0D"; -- ENTER (carriage return)
            when others => return x"00"; -- anything else is ignored
        end case;
    end function;

    -- General constants
    constant DEBOUNCE_MAX   : integer := sel_int(SIM_FAST, 16, 1_000_000); -- 1,000,000 cycles = 20 ms
    constant NUM_WORDS      : integer := 30;
    constant MAX_WORD_LEN   : integer := 10;
    constant MAX_ERRORS     : integer := 6;

    -- PS/2 constants
    constant PS2_TIMEOUT    : integer := 100_000;                          -- 2 ms without clock edge = frame aborted
    constant KEY_LED_TIME   : integer := sel_int(SIM_FAST, 1_000, 4_000_000); -- LED activity stretch, ~80 ms

    -- LCD timing constants (number of 50 MHz clock cycles). The timer counts down to 0,
    -- so the real wait is (value + 1) cycles.
    constant LCD_POWER_ON   : integer := sel_int(SIM_FAST, 200, 1_000_000); -- 20 ms (datasheet asks >15 ms)
    constant LCD_WAIT_5MS   : integer := sel_int(SIM_FAST, 100, 250_000);   -- after 1st 0x3 (datasheet asks >4.1 ms)
    constant LCD_WAIT_200US : integer := 10_000;                            -- after 2nd 0x3 (>100 us)
    constant LCD_WAIT_100US : integer := 5_000;                             -- after 3rd 0x3 and 0x2 (>40 us)
    constant LCD_WAIT_50US  : integer := 2_500;                             -- normal command / character (>40 us)
    constant LCD_WAIT_2MS   : integer := sel_int(SIM_FAST, 100, 100_000);   -- clear display (>1.64 ms)
    constant LCD_T_SETUP    : integer := 4;                                 -- RS/data stable before E rises (>40 ns)
    constant LCD_T_EHIGH    : integer := 12;                                -- E high time, 13 cycles = 260 ns (>230 ns)
    constant LCD_T_GAP      : integer := 50;                                -- 1 us after E falls
    constant LCD_LAST_STEP  : integer := 41;                                -- last step of the refresh sequence

    constant BLINK_BIT      : integer := sel_int(SIM_FAST, 17, 26);         -- bit of blink counter, ~1.3 s period/2

    -- Types
    type game_state_type is (S_INIT, S_IDLE, S_NEW_GAME, S_LOAD_WORD, S_PLAYING, S_WIN, S_LOSE);
    type lcd_state_type  is (L_POWER_ON, L_LOAD, L_SETUP, L_E_HIGH, L_E_LOW, L_WAIT);

    type word_rom_type   is array (0 to NUM_WORDS-1) of string(1 to MAX_WORD_LEN);
    type len_rom_type    is array (0 to NUM_WORDS-1) of integer range 0 to MAX_WORD_LEN;
    type secret_type     is array (0 to MAX_WORD_LEN-1) of std_logic_vector(7 downto 0);
    type lcd_buf_type    is array (0 to 31) of std_logic_vector(7 downto 0); -- 2 lines x 16 chars

    -- Word database (read by the logic of section 8). Each word is padded with spaces up to 10 chars
    constant WORD_ROM : word_rom_type := (
        "FPGA      ",   --  0
        "CIRCUITO  ",   --  1
        "ROBOTICA  ",   --  2
        "DIGITAL   ",   --  3
        "MEMORIA   ",   --  4
        "TECLADO   ",   --  5
        "DISPLAY   ",   --  6
        "SENSOR    ",   --  7
        "PROGRAMA  ",   --  8
        "HARDWARE  ",   --  9
        "SOFTWARE  ",   -- 10
        "ENERGIA   ",   -- 11
        "BATERIA   ",   -- 12
        "INTERNET  ",   -- 13
        "CODIGO    ",   -- 14
        "COMPUTADOR",   -- 15
        "ELETRONICA",   -- 16
        "ENGENHARIA",   -- 17
        "SISTEMAS  ",   -- 18
        "BARRAMENTO",   -- 19
        "ALGORITMO ",   -- 20
        "RESISTOR  ",   -- 21
        "CAPACITOR ",   -- 22
        "TRANSISTOR",   -- 23
        "CORRENTE  ",   -- 24
        "TENSAO    ",   -- 25
        "FREQUENCIA",   -- 26
        "MICROCHIP ",   -- 27
        "PROTOCOLO ",   -- 28
        "LOGICA    "    -- 29
    );

    -- Real length of each word above (same order)
    constant LEN_ROM : len_rom_type := (
         4,  8,  8,  7,  7,  7,  7,  6,  8,  8,
         8,  7,  7,  8,  6, 10, 10, 10,  8, 10,
         9,  8,  9, 10,  8,  5, 10,  9,  9,  6
    );

    -- Fixed LCD messages, always exactly 16 characters
    constant MSG_TITLE   : string(1 to 16) := "      FORCA     ";
    constant MSG_PRESS   : string(1 to 16) := "ENTER P/ INICIAR";
    constant MSG_WIN     : string(1 to 16) := "  VOCE VENCEU!  ";
    constant MSG_LOSE    : string(1 to 16) := "  VOCE PERDEU!  ";
    constant MSG_NEWGAME : string(1 to 16) := "ENTER: NOVO JOGO";
    constant MSG_ERRORS  : string(1 to 16) := "ERROS: 00/06 [ ]"; -- error digit and last letter are overwritten
    constant MSG_ANSWER  : string(1 to 16) := "ERA:            "; -- the secret word is written after "ERA: "

    -- =====================================================================
    -- 3. INTERNAL SIGNALS
    -- =====================================================================

    -- Reset button (synchronizer + debouncer)
    signal rst_sync       : std_logic_vector(1 downto 0) := (others => '0');
    signal rst_stable     : std_logic := '0';
    signal rst_cnt        : integer range 0 to DEBOUNCE_MAX := 0;
    signal rst_int        : std_logic := '0';  -- clean reset used by every process

    -- BTN_WEST (synchronizer + debouncer + pulse)
    signal btn_sync       : std_logic_vector(1 downto 0) := (others => '0');
    signal btn_stable     : std_logic := '0';
    signal btn_prev       : std_logic := '0';
    signal btn_pulse      : std_logic := '0';
    signal btn_cnt        : integer range 0 to DEBOUNCE_MAX := 0;

    -- Switches synchronizer
    signal sw_sync0       : std_logic_vector(3 downto 0) := (others => '0');
    signal sw_sync1       : std_logic_vector(3 downto 0) := (others => '0');

    -- PS/2 synchronizer and clock filter
    signal ps2_clk_sync   : std_logic_vector(1 downto 0) := (others => '1');
    signal ps2_data_sync  : std_logic_vector(1 downto 0) := (others => '1');
    signal ps2_clk_hist   : std_logic_vector(7 downto 0) := (others => '1');
    signal ps2_clk_filt   : std_logic := '1';
    signal ps2_clk_prev   : std_logic := '1';
    signal ps2_fall       : std_logic := '0';

    -- PS/2 receiver
    signal ps2_bit_cnt    : integer range 0 to 10 := 0;
    signal ps2_shift      : std_logic_vector(7 downto 0) := (others => '0');
    signal ps2_par_calc   : std_logic := '0';
    signal ps2_par_bit    : std_logic := '0';
    signal ps2_timeout    : integer range 0 to PS2_TIMEOUT := PS2_TIMEOUT;
    signal ps2_byte       : std_logic_vector(7 downto 0) := (others => '0');
    signal ps2_byte_valid : std_logic := '0';

    -- Keyboard decoder
    signal kbd_break      : std_logic := '0';  -- '1' after F0 (next code is a key release)
    signal kbd_ext        : std_logic := '0';  -- '1' after E0 (extended key, ignored)
    signal kbd_held       : std_logic := '0';  -- '1' while the last accepted key is still pressed
    signal kbd_held_code  : std_logic_vector(7 downto 0) := (others => '0');
    signal key_valid      : std_logic := '0';  -- 1-cycle pulse: a new key was pressed
    signal key_ascii      : std_logic_vector(7 downto 0) := (others => '0');
    signal enter_evt      : std_logic := '0';
    signal letter_evt     : std_logic := '0';

    -- LFSR
    signal lfsr           : std_logic_vector(7 downto 0) := x"A5"; -- must never be all zeros

    -- Word database output
    signal rom_word       : string(1 to MAX_WORD_LEN);
    signal rom_len        : integer range 0 to MAX_WORD_LEN := 0;

    -- Game controller
    signal game_state     : game_state_type := S_INIT;
    signal secret         : secret_type := (others => x"20");
    signal secret_len     : integer range 0 to MAX_WORD_LEN := 0;
    signal revealed       : std_logic_vector(MAX_WORD_LEN-1 downto 0) := (others => '0');
    signal used_letters   : std_logic_vector(25 downto 0) := (others => '0'); -- bit 0 = A ... bit 25 = Z
    signal error_cnt      : integer range 0 to MAX_ERRORS := 0;
    signal last_letter    : std_logic_vector(7 downto 0) := x"20";
    signal rand_val       : integer range 0 to 255 := 0;
    signal word_idx       : integer range 0 to NUM_WORDS-1 := 0;

    -- LCD controller
    signal lcd_buf        : lcd_buf_type := (others => x"20");
    signal lcd_state      : lcd_state_type := L_POWER_ON;
    signal lcd_timer      : integer range 0 to 1_000_000 := LCD_POWER_ON;
    signal lcd_seq        : integer range 0 to LCD_LAST_STEP := 0;
    signal lcd_phase_low  : std_logic := '0';  -- '0' = sending high nibble, '1' = low nibble
    signal lcd_nib_only   : std_logic := '0';  -- '1' = only the high nibble is sent (init sequence)
    signal lcd_tx_byte    : std_logic_vector(7 downto 0) := (others => '0');
    signal lcd_tx_rs      : std_logic := '0';
    signal lcd_tx_wait    : integer range 0 to 1_000_000 := 0;
    signal lcd_ready      : std_logic := '0';
    signal lcd_e_r        : std_logic := '0';
    signal lcd_rs_r       : std_logic := '0';
    signal lcd_data_r     : std_logic_vector(7 downto 4) := (others => '0');
    signal blink_cnt      : unsigned(26 downto 0) := (others => '0');

    -- LEDs
    signal led_reg        : std_logic_vector(7 downto 0) := (others => '0');
    signal key_led_cnt    : integer range 0 to 4_000_000 := 0;

begin

    -- =====================================================================
    -- 3.1 RESET BUTTON AND BTN_WEST (conventional synchronizer + debouncer)
    --     The debouncer is used ONLY on mechanical buttons, never on PS/2.
    -- =====================================================================

    -- Reset: two flip-flop synchronizer
    p_rst_sync : process(clk)
    begin
        if rising_edge(clk) then
            rst_sync(0) <= rst;
            rst_sync(1) <= rst_sync(0);
        end if;
    end process p_rst_sync;

    -- Reset: the new level is accepted only after 20 ms without changes.
    -- (This block has no reset itself, otherwise it would depend on its own output.)
    p_rst_debounce : process(clk)
    begin
        if rising_edge(clk) then
            if rst_sync(1) /= rst_stable then
                if rst_cnt = DEBOUNCE_MAX then
                    rst_stable <= rst_sync(1);
                    rst_cnt    <= 0;
                else
                    rst_cnt <= rst_cnt + 1;
                end if;
            else
                rst_cnt <= 0;
            end if;
        end if;
    end process p_rst_debounce;

    rst_int <= rst_stable;

    -- BTN_WEST: synchronizer, debouncer and rising-edge pulse
    p_btn : process(clk)
    begin
        if rising_edge(clk) then
            if rst_int = '1' then
                btn_sync   <= (others => '0');
                btn_stable <= '0';
                btn_prev   <= '0';
                btn_pulse  <= '0';
                btn_cnt    <= 0;
            else
                btn_sync(0) <= btn_in;
                btn_sync(1) <= btn_sync(0);

                if btn_sync(1) /= btn_stable then
                    if btn_cnt = DEBOUNCE_MAX then
                        btn_stable <= btn_sync(1);
                        btn_cnt    <= 0;
                    else
                        btn_cnt <= btn_cnt + 1;
                    end if;
                else
                    btn_cnt <= 0;
                end if;

                btn_prev  <= btn_stable;
                btn_pulse <= btn_stable and (not btn_prev); -- 0 -> 1 edge
            end if;
        end if;
    end process p_btn;

    -- Switches only need synchronization (they are static)
    p_sw_sync : process(clk)
    begin
        if rising_edge(clk) then
            sw_sync0 <= switches;
            sw_sync1 <= sw_sync0;
        end if;
    end process p_sw_sync;

    -- =====================================================================
    -- 4. PS/2 SYNCHRONIZER
    --    PS2_CLK and PS2_DATA are asynchronous to the 50 MHz clock, so each one goes
    --    through 2 flip-flops. PS2_CLK also passes through a small glitch filter:
    --    the filtered clock only changes after 8 equal samples (160 ns). The PS/2
    --    clock is only 10-16 kHz (period >= 60 us), so this delay is harmless.
    --    NO 20 ms debouncer here: it would swallow the whole serial frame.
    -- =====================================================================
    p_ps2_sync : process(clk)
    begin
        if rising_edge(clk) then
            if rst_int = '1' then
                ps2_clk_sync  <= (others => '1');
                ps2_data_sync <= (others => '1');
                ps2_clk_hist  <= (others => '1');
                ps2_clk_filt  <= '1';
                ps2_clk_prev  <= '1';
            else
                -- Stage 1 and 2: synchronizers
                ps2_clk_sync(0)  <= ps2_clk;
                ps2_clk_sync(1)  <= ps2_clk_sync(0);
                ps2_data_sync(0) <= ps2_data;
                ps2_data_sync(1) <= ps2_data_sync(0);

                -- Glitch filter: history of the last 8 samples of the clock
                ps2_clk_hist <= ps2_clk_hist(6 downto 0) & ps2_clk_sync(1);
                if ps2_clk_hist = "11111111" then
                    ps2_clk_filt <= '1';
                elsif ps2_clk_hist = "00000000" then
                    ps2_clk_filt <= '0';
                end if;

                -- Previous value, used to find the falling edge
                ps2_clk_prev <= ps2_clk_filt;
            end if;
        end if;
    end process p_ps2_sync;

    -- Falling edge of the filtered PS/2 clock: this is the moment when the data bit is valid
    ps2_fall <= ps2_clk_prev and (not ps2_clk_filt);

    -- =====================================================================
    -- 5. PS/2 RECEIVER
    --    Frame = 11 bits, sent by the keyboard, one bit per falling clock edge:
    --      bit 0     : start bit (always '0')
    --      bits 1-8  : data, LSB first
    --      bit 9     : parity (ODD parity: data + parity have an odd number of '1')
    --      bit 10    : stop bit (always '1')
    --    A byte is only accepted if start = 0, stop = 1 and the parity is right.
    --    If the clock stays quiet for 2 ms in the middle of a frame the counter is
    --    cleared, so the receiver can recover from any corrupted frame.
    -- =====================================================================
    p_ps2_rx : process(clk)
    begin
        if rising_edge(clk) then
            ps2_byte_valid <= '0'; -- default: pulse of only 1 cycle

            if rst_int = '1' then
                ps2_bit_cnt <= 0;
                ps2_shift   <= (others => '0');
                ps2_par_calc <= '0';
                ps2_par_bit  <= '0';
                ps2_timeout  <= PS2_TIMEOUT;
                ps2_byte     <= (others => '0');
            elsif ps2_fall = '1' then
                ps2_timeout <= 0;

                case ps2_bit_cnt is
                    when 0 =>
                        -- Start bit: must be '0', otherwise stay waiting
                        if ps2_data_sync(1) = '0' then
                            ps2_par_calc <= '0';
                            ps2_bit_cnt  <= 1;
                        end if;

                    when 1 to 8 =>
                        -- Data bits, LSB first: new bit enters on the left, shifts right
                        ps2_shift    <= ps2_data_sync(1) & ps2_shift(7 downto 1);
                        ps2_par_calc <= ps2_par_calc xor ps2_data_sync(1);
                        ps2_bit_cnt  <= ps2_bit_cnt + 1;

                    when 9 =>
                        -- Parity bit
                        ps2_par_bit <= ps2_data_sync(1);
                        ps2_bit_cnt <= 10;

                    when others =>
                        -- Stop bit (bit 10): check stop = 1 and odd parity (xor of data+parity = 1)
                        if ps2_data_sync(1) = '1' and (ps2_par_calc xor ps2_par_bit) = '1' then
                            ps2_byte       <= ps2_shift;
                            ps2_byte_valid <= '1';
                        end if;
                        ps2_bit_cnt <= 0;
                end case;
            else
                -- No clock edge in this cycle: count time without activity
                if ps2_timeout = PS2_TIMEOUT then
                    ps2_bit_cnt <= 0; -- abandon an incomplete frame
                else
                    ps2_timeout <= ps2_timeout + 1;
                end if;
            end if;
        end if;
    end process p_ps2_rx;

    -- =====================================================================
    -- 6. KEYBOARD DECODER (scan code set 2)
    --    Pressing a key sends its MAKE code. Releasing sends F0 followed by the
    --    same code (BREAK). Holding a key repeats the make code over and over
    --    (typematic) without any F0. Extended keys are preceded by E0.
    --    Rule used here:
    --      * make code of a supported key -> generates ONE event (key_valid)
    --        and the key is marked as "held";
    --      * the same make code again while held -> typematic repeat, ignored;
    --      * F0 + code of the held key -> key released, it can generate a new event;
    --      * E0 codes (arrows, keypad ENTER...) and unknown codes are ignored.
    -- =====================================================================
    p_kbd : process(clk)
        variable v_ascii : std_logic_vector(7 downto 0);
    begin
        if rising_edge(clk) then
            key_valid <= '0'; -- default: pulse of only 1 cycle

            if rst_int = '1' then
                kbd_break     <= '0';
                kbd_ext       <= '0';
                kbd_held      <= '0';
                kbd_held_code <= (others => '0');
                key_ascii     <= (others => '0');
            elsif ps2_byte_valid = '1' then
                if ps2_byte = x"F0" then
                    kbd_break <= '1';                 -- next code is a release
                elsif ps2_byte = x"E0" then
                    kbd_ext <= '1';                   -- next code belongs to an extended key
                else
                    v_ascii   := scan_to_ascii(ps2_byte);
                    kbd_break <= '0';
                    kbd_ext   <= '0';

                    if kbd_ext = '1' then
                        null;                         -- extended key: ignored
                    elsif kbd_break = '1' then
                        -- Release: only the key that is being held is cleared
                        if kbd_held = '1' and ps2_byte = kbd_held_code then
                            kbd_held <= '0';
                        end if;
                    elsif v_ascii /= x"00" then
                        -- Make code of a supported key
                        if kbd_held = '1' and ps2_byte = kbd_held_code then
                            null;                     -- typematic repeat: ignored
                        else
                            key_valid     <= '1';
                            key_ascii     <= v_ascii;
                            kbd_held      <= '1';
                            kbd_held_code <= ps2_byte;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process p_kbd;

    -- ENTER can come from the keyboard or from BTN_WEST. Letters only come from the keyboard.
    enter_evt  <= '1' when (key_valid = '1' and key_ascii = x"0D") or btn_pulse = '1' else '0';
    letter_evt <= '1' when (key_valid = '1' and key_ascii /= x"0D") else '0';

    -- =====================================================================
    -- 7. RANDOM NUMBER GENERATOR (LFSR)
    --    8-bit Fibonacci LFSR, polynomial x^8 + x^6 + x^5 + x^4 + 1 (taps 8,6,5,4),
    --    which is a maximal-length polynomial: it visits all 255 non-zero values
    --    before repeating. The all-zeros value is the "lock-up" state of an XOR
    --    LFSR, so the seed is non-zero (A5) and it can never reach zero.
    --    It runs at 50 MHz all the time, so the value read when the player presses
    --    ENTER depends on the exact instant of the key press (the pseudo-random part).
    --    Conversion to a valid index 0..29 is done by the game controller
    --    (state S_NEW_GAME): while value >= 30, subtract 30. For 1..255 this takes at most
    --    8 clock cycles and the result is always in 0..29, so it can never point outside
    --    the word table. (Small bias: indexes 0..15 are slightly more likely, since 255 is
    --    not a multiple of 30. Not important for a game.)
    -- =====================================================================
    p_lfsr : process(clk)
    begin
        if rising_edge(clk) then
            if rst_int = '1' then
                lfsr <= x"A5";
            else
                lfsr <= lfsr(6 downto 0) & (lfsr(7) xor lfsr(5) xor lfsr(4) xor lfsr(3));
            end if;
        end if;
    end process p_lfsr;

    -- =====================================================================
    -- 8. WORD DATABASE
    --    The table is declared in section 2 (WORD_ROM and LEN_ROM). It is read here
    --    combinationally with word_idx, so the synthesizer builds a small ROM in LUTs.
    -- =====================================================================
    rom_word <= WORD_ROM(word_idx);
    rom_len  <= LEN_ROM(word_idx);

    -- =====================================================================
    -- 9. GAME CONTROLLER (main FSM)
    --    S_INIT      : wait until the LCD finishes its initialization
    --    S_IDLE      : title screen, wait for ENTER
    --    S_NEW_GAME  : choose the word index (switches or LFSR mod 30)
    --    S_LOAD_WORD : copy the word from the ROM and clear the game data
    --    S_PLAYING   : process the letters typed by the player
    --    S_WIN       : all letters found, ENTER = new game
    --    S_LOSE      : 6 errors reached, ENTER = new game
    --    This is the ONLY process that writes the game signals.
    -- =====================================================================
    p_game : process(clk)
        variable v_idx   : integer range 0 to 25;
        variable v_found : boolean;
        variable v_all   : boolean;
        variable v_rev   : std_logic_vector(MAX_WORD_LEN-1 downto 0);
    begin
        if rising_edge(clk) then
            if rst_int = '1' then
                game_state   <= S_INIT;
                secret       <= (others => x"20");
                secret_len   <= 0;
                revealed     <= (others => '0');
                used_letters <= (others => '0');
                error_cnt    <= 0;
                last_letter  <= x"20";
                rand_val     <= 0;
                word_idx     <= 0;
            else
                case game_state is

                    when S_INIT =>
                        if lcd_ready = '1' then
                            game_state <= S_IDLE;
                        end if;

                    when S_IDLE =>
                        if enter_evt = '1' then
                            rand_val   <= to_integer(unsigned(lfsr)); -- take a snapshot of the LFSR
                            game_state <= S_NEW_GAME;
                        end if;

                    when S_NEW_GAME =>
                        if sw_sync1 /= "0000" then
                            -- Test mode: switches 0001..1111 select words 0..14
                            word_idx   <= to_integer(unsigned(sw_sync1)) - 1;
                            game_state <= S_LOAD_WORD;
                        elsif rand_val >= NUM_WORDS then
                            rand_val <= rand_val - NUM_WORDS; -- subtract 30 until the value is below 30
                        else
                            word_idx   <= rand_val;           -- valid index 0..29
                            game_state <= S_LOAD_WORD;
                        end if;

                    when S_LOAD_WORD =>
                        for i in 0 to MAX_WORD_LEN-1 loop
                            secret(i) <= chr(rom_word(i+1));
                        end loop;
                        secret_len   <= rom_len;
                        revealed     <= (others => '0');
                        used_letters <= (others => '0');
                        error_cnt    <= 0;
                        last_letter  <= x"20";
                        game_state   <= S_PLAYING;

                    when S_PLAYING =>
                        -- Only letters A-Z are processed. ENTER is ignored while playing.
                        if letter_evt = '1' and
                           unsigned(key_ascii) >= 65 and unsigned(key_ascii) <= 90 then

                            v_idx := to_integer(unsigned(key_ascii)) - 65; -- A=0 ... Z=25

                            -- A letter already used is ignored (does not cost an attempt)
                            if used_letters(v_idx) = '0' then
                                used_letters(v_idx) <= '1';
                                last_letter         <= key_ascii;

                                -- Reveal every occurrence of the letter
                                v_found := false;
                                v_rev   := revealed;
                                for i in 0 to MAX_WORD_LEN-1 loop
                                    if i < secret_len and secret(i) = key_ascii then
                                        v_rev(i) := '1';
                                        v_found  := true;
                                    end if;
                                end loop;
                                revealed <= v_rev;

                                if v_found then
                                    -- Win if every position of the word is revealed
                                    v_all := true;
                                    for i in 0 to MAX_WORD_LEN-1 loop
                                        if i < secret_len and v_rev(i) = '0' then
                                            v_all := false;
                                        end if;
                                    end loop;
                                    if v_all then
                                        game_state <= S_WIN;
                                    end if;
                                else
                                    -- Wrong letter: one more error
                                    error_cnt <= error_cnt + 1;
                                    if error_cnt + 1 >= MAX_ERRORS then
                                        game_state <= S_LOSE;
                                    end if;
                                end if;
                            end if;
                        end if;

                    when S_WIN | S_LOSE =>
                        if enter_evt = '1' then
                            rand_val   <= to_integer(unsigned(lfsr));
                            game_state <= S_NEW_GAME;
                        end if;

                    when others =>
                        game_state <= S_INIT; -- protection against invalid states

                end case;
            end if;
        end if;
    end process p_game;

    -- =====================================================================
    -- 10. LCD CONTROLLER
    --     Display: 16x2 HD44780 compatible, 4-bit interface (DB7..DB4), write only (RW = 0).
    --     Two independent blocks:
    --       (a) p_lcd_format : writes what must be shown (32 characters) in lcd_buf,
    --                          according to the game state. It never talks to the LCD.
    --       (b) p_lcd_ctrl   : own FSM that initializes the LCD and then keeps rewriting
    --                          the whole lcd_buf over and over (about every 1.8 ms).
    --     So the game FSM only changes the buffer and never waits for the LCD.
    -- =====================================================================

    -- Free running counter used to alternate messages on the LOSE screen
    p_blink : process(clk)
    begin
        if rising_edge(clk) then
            blink_cnt <= blink_cnt + 1;
        end if;
    end process p_blink;

    -- (a) Screen formatter. Each handled state writes all 32 positions in the same clock,
    --     states that are not handled keep the previous screen (no blank flash).
    p_lcd_format : process(clk)
    begin
        if rising_edge(clk) then
            case game_state is

                when S_IDLE =>
                    for i in 0 to 15 loop
                        lcd_buf(i)      <= chr(MSG_TITLE(i+1));
                        lcd_buf(16 + i) <= chr(MSG_PRESS(i+1));
                    end loop;

                when S_PLAYING =>
                    -- Line 1: the word with '_' for the hidden letters.
                    -- Words up to 8 letters use a space between letters, longer ones do not fit.
                    for i in 0 to 15 loop
                        lcd_buf(i) <= x"20";
                    end loop;
                    if secret_len <= 8 then
                        for i in 0 to 7 loop
                            if i < secret_len then
                                if revealed(i) = '1' then
                                    lcd_buf(2*i) <= secret(i);
                                else
                                    lcd_buf(2*i) <= chr('_');
                                end if;
                            end if;
                        end loop;
                    else
                        for i in 0 to MAX_WORD_LEN-1 loop
                            if i < secret_len then
                                if revealed(i) = '1' then
                                    lcd_buf(i) <= secret(i);
                                else
                                    lcd_buf(i) <= chr('_');
                                end if;
                            end if;
                        end loop;
                    end if;
                    -- Line 2: "ERROS: 0X/06 [L]" (X = errors, L = last letter typed)
                    for i in 0 to 15 loop
                        lcd_buf(16 + i) <= chr(MSG_ERRORS(i+1));
                    end loop;
                    lcd_buf(16 + 8)  <= std_logic_vector(to_unsigned(48 + error_cnt, 8)); -- '0' + errors
                    lcd_buf(16 + 14) <= last_letter;

                when S_WIN =>
                    for i in 0 to 15 loop
                        lcd_buf(i)      <= chr(MSG_WIN(i+1));
                        lcd_buf(16 + i) <= chr(MSG_NEWGAME(i+1));
                    end loop;

                when S_LOSE =>
                    for i in 0 to 15 loop
                        lcd_buf(i) <= chr(MSG_LOSE(i+1));
                    end loop;
                    if blink_cnt(BLINK_BIT) = '0' then
                        -- Show the correct word: "ERA: WORD"
                        for i in 0 to 15 loop
                            lcd_buf(16 + i) <= chr(MSG_ANSWER(i+1));
                        end loop;
                        for i in 0 to MAX_WORD_LEN-1 loop
                            if i < secret_len then
                                lcd_buf(16 + 5 + i) <= secret(i);
                            end if;
                        end loop;
                    else
                        for i in 0 to 15 loop
                            lcd_buf(16 + i) <= chr(MSG_NEWGAME(i+1));
                        end loop;
                    end if;

                when others =>
                    null; -- S_INIT, S_NEW_GAME, S_LOAD_WORD: keep what is on the buffer

            end case;
        end if;
    end process p_lcd_format;

    -- (b) LCD driver FSM.
    --     The sequence is a list of "steps" (lcd_seq):
    --       0 to 3   : initialization nibbles 3,3,3,2 (4-bit mode, "initialization by instruction")
    --       4        : Function Set 0x28 (4-bit, 2 lines, 5x8 font)
    --       5        : Entry Mode Set 0x06 (cursor moves right)
    --       6        : Display ON 0x0C (cursor off)
    --       7        : Clear Display 0x01 (slow command, ~1.64 ms)
    --       8        : set cursor to line 1 (0x80)
    --       9 to 24  : 16 characters of line 1
    --       25       : set cursor to line 2 (0xC0)
    --       26 to 41 : 16 characters of line 2
    --     After step 41 it goes back to step 8, refreshing the screen forever.
    --     Each byte = high nibble + low nibble. Each nibble = setup (RS/data), E pulse, gap.
    p_lcd_ctrl : process(clk)
    begin
        if rising_edge(clk) then
            if rst_int = '1' then
                lcd_state     <= L_POWER_ON;
                lcd_timer     <= LCD_POWER_ON;
                lcd_seq       <= 0;
                lcd_phase_low <= '0';
                lcd_nib_only  <= '0';
                lcd_tx_byte   <= (others => '0');
                lcd_tx_rs     <= '0';
                lcd_tx_wait   <= 0;
                lcd_ready     <= '0';
                lcd_e_r       <= '0';
                lcd_rs_r      <= '0';
                lcd_data_r    <= (others => '0');
            else
                case lcd_state is

                    -- Wait for the LCD power-up (>15 ms)
                    when L_POWER_ON =>
                        if lcd_timer = 0 then
                            lcd_state <= L_LOAD;
                        else
                            lcd_timer <= lcd_timer - 1;
                        end if;

                    -- Prepare the byte of the current step (byte, RS and wait time after it)
                    when L_LOAD =>
                        lcd_phase_low <= '0';
                        lcd_nib_only  <= '0';
                        lcd_tx_rs     <= '0';
                        lcd_tx_wait   <= LCD_WAIT_50US;

                        if lcd_seq <= 3 then
                            lcd_nib_only <= '1'; -- only the high nibble is sent
                            case lcd_seq is
                                when 0 =>
                                    lcd_tx_byte <= x"30";
                                    lcd_tx_wait <= LCD_WAIT_5MS;
                                when 1 =>
                                    lcd_tx_byte <= x"30";
                                    lcd_tx_wait <= LCD_WAIT_200US;
                                when 2 =>
                                    lcd_tx_byte <= x"30";
                                    lcd_tx_wait <= LCD_WAIT_100US;
                                when others =>
                                    lcd_tx_byte <= x"20"; -- switch to 4-bit mode
                                    lcd_tx_wait <= LCD_WAIT_100US;
                            end case;
                        elsif lcd_seq = 4 then
                            lcd_tx_byte <= x"28";
                        elsif lcd_seq = 5 then
                            lcd_tx_byte <= x"06";
                        elsif lcd_seq = 6 then
                            lcd_tx_byte <= x"0C";
                        elsif lcd_seq = 7 then
                            lcd_tx_byte <= x"01";
                            lcd_tx_wait <= LCD_WAIT_2MS;
                        elsif lcd_seq = 8 then
                            lcd_tx_byte <= x"80";                  -- DDRAM address 0x00 (line 1)
                        elsif lcd_seq <= 24 then
                            lcd_tx_rs   <= '1';
                            lcd_tx_byte <= lcd_buf(lcd_seq - 9);   -- chars 0..15
                        elsif lcd_seq = 25 then
                            lcd_tx_byte <= x"C0";                  -- DDRAM address 0x40 (line 2)
                        else
                            lcd_tx_rs   <= '1';
                            lcd_tx_byte <= lcd_buf(lcd_seq - 10);  -- chars 16..31
                        end if;

                        lcd_timer <= LCD_T_SETUP;
                        lcd_state <= L_SETUP;

                    -- Put RS and the nibble on the bus with E low (setup time before E)
                    when L_SETUP =>
                        lcd_e_r  <= '0';
                        lcd_rs_r <= lcd_tx_rs;
                        if lcd_phase_low = '0' then
                            lcd_data_r <= lcd_tx_byte(7 downto 4);
                        else
                            lcd_data_r <= lcd_tx_byte(3 downto 0);
                        end if;
                        if lcd_timer = 0 then
                            lcd_timer <= LCD_T_EHIGH;
                            lcd_state <= L_E_HIGH;
                        else
                            lcd_timer <= lcd_timer - 1;
                        end if;

                    -- E pulse (the LCD reads the nibble on the falling edge of E)
                    when L_E_HIGH =>
                        lcd_e_r <= '1';
                        if lcd_timer = 0 then
                            lcd_timer <= LCD_T_GAP;
                            lcd_state <= L_E_LOW;
                        else
                            lcd_timer <= lcd_timer - 1;
                        end if;

                    -- E low, data hold and 1 us gap; then low nibble or wait after the byte
                    when L_E_LOW =>
                        lcd_e_r <= '0';
                        if lcd_timer = 0 then
                            if lcd_nib_only = '0' and lcd_phase_low = '0' then
                                lcd_phase_low <= '1';          -- now send the low nibble
                                lcd_timer     <= LCD_T_SETUP;
                                lcd_state     <= L_SETUP;
                            else
                                lcd_timer <= lcd_tx_wait;      -- command execution time
                                lcd_state <= L_WAIT;
                            end if;
                        else
                            lcd_timer <= lcd_timer - 1;
                        end if;

                    -- Wait for the LCD to execute the command, then go to the next step
                    when L_WAIT =>
                        if lcd_timer = 0 then
                            if lcd_seq = 7 then
                                lcd_ready <= '1';              -- init finished (clear display done)
                            end if;
                            if lcd_seq = LCD_LAST_STEP then
                                lcd_seq <= 8;                  -- refresh loop
                            else
                                lcd_seq <= lcd_seq + 1;
                            end if;
                            lcd_state <= L_LOAD;
                        else
                            lcd_timer <= lcd_timer - 1;
                        end if;

                    when others =>
                        lcd_state <= L_POWER_ON;
                        lcd_timer <= LCD_POWER_ON;

                end case;
            end if;
        end if;
    end process p_lcd_ctrl;

    -- =====================================================================
    -- 11. LED CONTROLLER
    --     led(2 downto 0) : number of errors in binary (0 to 6)
    --     led(3)          : game in progress (S_PLAYING)
    --     led(4)          : PS/2 activity (lights ~80 ms whenever a valid byte arrives)
    --     led(5)          : LCD initialized (ready)
    --     led(6)          : player WON
    --     led(7)          : player LOST
    -- =====================================================================
    p_led : process(clk)
    begin
        if rising_edge(clk) then
            if rst_int = '1' then
                led_reg     <= (others => '0');
                key_led_cnt <= 0;
            else
                led_reg(2 downto 0) <= std_logic_vector(to_unsigned(error_cnt, 3));

                if game_state = S_PLAYING then
                    led_reg(3) <= '1';
                else
                    led_reg(3) <= '0';
                end if;

                if ps2_byte_valid = '1' then
                    key_led_cnt <= KEY_LED_TIME;
                elsif key_led_cnt > 0 then
                    key_led_cnt <= key_led_cnt - 1;
                end if;
                if key_led_cnt > 0 then
                    led_reg(4) <= '1';
                else
                    led_reg(4) <= '0';
                end if;

                led_reg(5) <= lcd_ready;

                if game_state = S_WIN then
                    led_reg(6) <= '1';
                else
                    led_reg(6) <= '0';
                end if;

                if game_state = S_LOSE then
                    led_reg(7) <= '1';
                else
                    led_reg(7) <= '0';
                end if;
            end if;
        end if;
    end process p_led;

    -- =====================================================================
    -- 12. OUTPUT ASSIGNMENTS
    -- =====================================================================
    lcd_e  <= lcd_e_r;
    lcd_rs <= lcd_rs_r;
    lcd_rw <= '0';          -- write only: never read the LCD
    lcd_db <= lcd_data_r;
    led    <= led_reg;

end Behavioral;
