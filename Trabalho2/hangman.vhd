-- =========================================================================
-- Hangman (Forca) - 
-- PS/2 keyboard in, 16x2 LCD + LEDs out. Everything in one file.
-- =========================================================================

library IEEE;

use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity hangman is
    port (
        -- INPUT
        clk      : in  STD_LOGIC;                     -- 50 MHz clock
        rst      : in  STD_LOGIC;                     -- BTN_EAST (active high)
        btn_in   : in  STD_LOGIC;                     -- BTN_WEST, works like ENTER
        ps2_clk  : in  STD_LOGIC;                     -- keyboard clock
        ps2_data : in  STD_LOGIC;                     -- keyboard data

        -- OUTPUT
        lcd_e    : out STD_LOGIC;                     -- LCD enable
        lcd_rs   : out STD_LOGIC;                     -- 0 = command, 1 = data
        lcd_rw   : out STD_LOGIC;                     -- always 0 (write only)
        lcd_db   : out STD_LOGIC_VECTOR(7 downto 4);  -- 4-bit mode: only DB7..DB4
        led      : out STD_LOGIC_VECTOR(7 downto 0)
    );
end hangman;

architecture Behavioral of hangman is

    -- ---------------------------------------------------------------------
    -- Constants and types
    -- ---------------------------------------------------------------------
    constant DEBOUNCE_MAX  : integer := 1_000_000;   -- 20 ms
    constant PS2_TIMEOUT   : integer := 100_000;     -- 2 ms
    constant NUM_WORDS     : integer := 30;
    constant MAX_WORD_LEN  : integer := 10;
    constant MAX_ERRORS    : integer := 6;

    -- LCD waits, in clock cycles (the timer counts down to 0, so it is value+1)
    constant LCD_POWER_ON   : integer := 1_000_000;  -- 20 ms
    constant LCD_WAIT_5MS   : integer := 250_000;
    constant LCD_WAIT_200US : integer := 10_000;
    constant LCD_WAIT_100US : integer := 5_000;
    constant LCD_WAIT_50US  : integer := 2_500;
    constant LCD_WAIT_2MS   : integer := 100_000;
    constant LCD_LAST_STEP  : integer := 41;

    type game_state_type is (S_INIT, S_IDLE, S_NEW_GAME, S_LOAD_WORD, S_PLAYING, S_WIN, S_LOSE);
    type lcd_state_type  is (L_POWER_ON, L_LOAD, L_SETUP, L_E_HIGH, L_E_LOW, L_WAIT);

    type word_rom_type is array (0 to NUM_WORDS-1) of string(1 to MAX_WORD_LEN);
    type len_rom_type  is array (0 to NUM_WORDS-1) of integer range 0 to MAX_WORD_LEN;
    type secret_type   is array (0 to MAX_WORD_LEN-1) of std_logic_vector(7 downto 0);
    type lcd_buf_type  is array (0 to 31) of std_logic_vector(7 downto 0);

    -- words padded with spaces up to 10 chars
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

    -- real size of each word, same order as above
    constant LEN_ROM : len_rom_type := (
         4,  8,  8,  7,  7,  7,  7,  6,  8,  8,
         8,  7,  7,  8,  6, 10, 10, 10,  8, 10,
         9,  8,  9, 10,  8,  6, 10,  9,  9,  6
    );

    -- screen messages (16 chars each)
    constant MSG_TITLE   : string(1 to 16) := "      FORCA     ";
    constant MSG_PRESS   : string(1 to 16) := "ENTER P/ INICIAR";
    constant MSG_WIN     : string(1 to 16) := "  VOCE VENCEU!  ";
    constant MSG_LOSE    : string(1 to 16) := "  VOCE PERDEU!  ";
    constant MSG_NEWGAME : string(1 to 16) := "ENTER: NOVO JOGO";
    constant MSG_ERRORS  : string(1 to 16) := "ERROS: 00/06 [ ]";  -- digit and letter get overwritten
    constant MSG_ANSWER  : string(1 to 16) := "ERA:            ";  -- word goes after "ERA: "

    -- char -> ASCII code
    function chr (c : character) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(character'pos(c), 8));
    end function;

    -- PS/2 scan code set 2 -> ASCII, x"00" if the key is not used
    function scan_to_ascii (sc : std_logic_vector(7 downto 0)) return std_logic_vector is
    begin
        case sc is
            when x"1C" => return x"41";  -- A
            when x"32" => return x"42";  -- B
            when x"21" => return x"43";  -- C
            when x"23" => return x"44";  -- D
            when x"24" => return x"45";  -- E
            when x"2B" => return x"46";  -- F
            when x"34" => return x"47";  -- G
            when x"33" => return x"48";  -- H
            when x"43" => return x"49";  -- I
            when x"3B" => return x"4A";  -- J
            when x"42" => return x"4B";  -- K
            when x"4B" => return x"4C";  -- L
            when x"3A" => return x"4D";  -- M
            when x"31" => return x"4E";  -- N
            when x"44" => return x"4F";  -- O
            when x"4D" => return x"50";  -- P
            when x"15" => return x"51";  -- Q
            when x"2D" => return x"52";  -- R
            when x"1B" => return x"53";  -- S
            when x"2C" => return x"54";  -- T
            when x"3C" => return x"55";  -- U
            when x"2A" => return x"56";  -- V
            when x"1D" => return x"57";  -- W
            when x"22" => return x"58";  -- X
            when x"35" => return x"59";  -- Y
            when x"1A" => return x"5A";  -- Z
            when x"5A" => return x"0D";  -- ENTER
            when others => return x"00";
        end case;
    end function;

    -- ---------------------------------------------------------------------
    -- Signals
    -- ---------------------------------------------------------------------
    -- reset and button debounce
    signal rst_sync    : std_logic_vector(1 downto 0) := "00";
    signal rst_int     : std_logic := '0';                 -- debounced reset used everywhere
    signal rst_cnt     : integer range 0 to DEBOUNCE_MAX := 0;
    signal btn_sync    : std_logic_vector(1 downto 0) := "00";
    signal btn_stable  : std_logic := '0';
    signal btn_prev    : std_logic := '0';
    signal btn_pulse   : std_logic := '0';
    signal btn_cnt     : integer range 0 to DEBOUNCE_MAX := 0;

    -- PS/2 input
    signal ps2_clk_sync  : std_logic_vector(1 downto 0) := "11";
    signal ps2_data_sync : std_logic_vector(1 downto 0) := "11";
    signal ps2_clk_hist  : std_logic_vector(7 downto 0) := (others => '1');
    signal ps2_clk_filt  : std_logic := '1';
    signal ps2_clk_prev  : std_logic := '1';
    signal ps2_fall      : std_logic;

    -- PS/2 receiver
    signal ps2_bit_cnt    : integer range 0 to 10 := 0;
    signal ps2_shift      : std_logic_vector(7 downto 0) := (others => '0');
    signal ps2_par_calc   : std_logic := '0';
    signal ps2_par_bit    : std_logic := '0';
    signal ps2_timeout_sig    : integer range 0 to PS2_TIMEOUT := PS2_TIMEOUT;
    signal ps2_byte       : std_logic_vector(7 downto 0) := (others => '0');
    signal ps2_byte_valid : std_logic := '0';

    -- keyboard decoder
    signal kbd_break     : std_logic := '0';   -- last byte was F0
    signal kbd_ext       : std_logic := '0';   -- last byte was E0
    signal kbd_held      : std_logic := '0';   -- a key is still pressed
    signal kbd_held_code : std_logic_vector(7 downto 0) := (others => '0');
    signal key_valid     : std_logic := '0';   -- 1 cycle pulse per key press
    signal key_ascii     : std_logic_vector(7 downto 0) := (others => '0');
    signal enter_evt     : std_logic;
    signal letter_evt    : std_logic;

    signal lfsr : std_logic_vector(7 downto 0) := x"A5";

    -- word rom output
    signal rom_word : string(1 to MAX_WORD_LEN);
    signal rom_len  : integer range 0 to MAX_WORD_LEN;

    -- game
    signal game_state   : game_state_type := S_INIT;
    signal secret       : secret_type := (others => x"20");
    signal secret_len   : integer range 0 to MAX_WORD_LEN := 0;
    signal revealed     : std_logic_vector(MAX_WORD_LEN-1 downto 0) := (others => '0');
    signal used_letters : std_logic_vector(25 downto 0) := (others => '0');  -- bit 0 = A
    signal error_cnt    : integer range 0 to MAX_ERRORS := 0;
    signal last_letter  : std_logic_vector(7 downto 0) := x"20";
    signal rand_val     : integer range 0 to 255 := 0;
    signal word_idx     : integer range 0 to NUM_WORDS-1 := 0;

    -- LCD
    signal lcd_buf       : lcd_buf_type := (others => x"20");
    signal lcd_state     : lcd_state_type := L_POWER_ON;
    signal lcd_timer     : integer range 0 to 1_000_000 := LCD_POWER_ON;
    signal lcd_seq       : integer range 0 to LCD_LAST_STEP := 0;
    signal lcd_phase_low : std_logic := '0';   -- 0 = high nibble, 1 = low nibble
    signal lcd_nib_only  : std_logic := '0';   -- init steps send only one nibble
    signal lcd_tx_byte   : std_logic_vector(7 downto 0) := (others => '0');
    signal lcd_tx_rs     : std_logic := '0';
    signal lcd_tx_wait   : integer range 0 to 1_000_000 := 0;
    signal lcd_ready     : std_logic := '0';
    signal blink_cnt     : unsigned(26 downto 0) := (others => '0');

    signal key_led : std_logic := '0';

begin

    -- ---------------------------------------------------------------------
    -- Reset and BTN_WEST: 2 FF synchronizer + 20 ms debouncer
    -- (the reset debouncer has no reset, it would depend on itself)
    -- ---------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            rst_sync(0) <= rst;
            rst_sync(1) <= rst_sync(0);

            if rst_sync(1) /= rst_int then
                if rst_cnt = DEBOUNCE_MAX then
                    rst_int <= rst_sync(1);
                    rst_cnt <= 0;
                else
                    rst_cnt <= rst_cnt + 1;
                end if;
            else
                rst_cnt <= 0;
            end if;
        end if;
    end process;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst_int = '1' then
                btn_sync   <= "00";
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
                btn_pulse <= btn_stable and (not btn_prev);  -- rising edge
            end if;
        end if;
    end process;

    -- ---------------------------------------------------------------------
    -- PS/2 synchronizer
    -- 2 FFs on each line, plus a small glitch filter on the clock (it only
    -- changes after 8 equal samples = 160 ns). No 20 ms debouncer here, the
    -- PS/2 clock is only ~10 kHz and it would kill the frame.
    -- ---------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_int = '1' then
                ps2_clk_sync  <= "11";
                ps2_data_sync <= "11";
                ps2_clk_hist  <= (others => '1');
                ps2_clk_filt  <= '1';
                ps2_clk_prev  <= '1';
            else
                ps2_clk_sync(0)  <= ps2_clk;
                ps2_clk_sync(1)  <= ps2_clk_sync(0);
                ps2_data_sync(0) <= ps2_data;
                ps2_data_sync(1) <= ps2_data_sync(0);

                ps2_clk_hist <= ps2_clk_hist(6 downto 0) & ps2_clk_sync(1);
                if ps2_clk_hist = "11111111" then
                    ps2_clk_filt <= '1';
                elsif ps2_clk_hist = "00000000" then
                    ps2_clk_filt <= '0';
                end if;

                ps2_clk_prev <= ps2_clk_filt;
            end if;
        end if;
    end process;

    -- the data bit is valid on the falling edge of the keyboard clock
    ps2_fall <= ps2_clk_prev and (not ps2_clk_filt);

    -- ---------------------------------------------------------------------
    -- PS/2 receiver
    -- Frame has 11 bits, one per falling edge:
    --   0 = start ('0'), 1..8 = data (LSB first), 9 = odd parity, 10 = stop ('1')
    -- A byte is accepted only if start, parity and stop are all correct.
    -- If the clock stops for 2 ms in the middle of a frame we start over.
    -- ---------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            ps2_byte_valid <= '0';

            if rst_int = '1' then
                ps2_bit_cnt <= 0;
                ps2_timeout_sig <= PS2_TIMEOUT;
            elsif ps2_fall = '1' then
                ps2_timeout_sig <= 0;

                case ps2_bit_cnt is
                    when 0 =>
                        if ps2_data_sync(1) = '0' then   -- valid start bit
                            ps2_par_calc <= '0';
                            ps2_bit_cnt  <= 1;
                        end if;

                    when 1 to 8 =>
                        -- new bit enters from the left, so the first one ends up in bit 0
                        ps2_shift    <= ps2_data_sync(1) & ps2_shift(7 downto 1);
                        ps2_par_calc <= ps2_par_calc xor ps2_data_sync(1);
                        ps2_bit_cnt  <= ps2_bit_cnt + 1;

                    when 9 =>
                        ps2_par_bit <= ps2_data_sync(1);
                        ps2_bit_cnt <= 10;

                    when others =>
                        -- odd parity: data xor parity must be 1
                        if ps2_data_sync(1) = '1' and (ps2_par_calc xor ps2_par_bit) = '1' then
                            ps2_byte       <= ps2_shift;
                            ps2_byte_valid <= '1';
                        end if;
                        ps2_bit_cnt <= 0;
                end case;
            elsif ps2_timeout_sig = PS2_TIMEOUT then
                ps2_bit_cnt <= 0;
            else
                ps2_timeout_sig <= ps2_timeout_sig + 1;
            end if;
        end if;
    end process;

    -- ---------------------------------------------------------------------
    -- Keyboard decoder (scan code set 2)
    -- Press = make code. Release = F0 + same code. Holding a key repeats the
    -- make code with no F0 in between, so a key only generates an event if it
    -- is not already marked as held. E0 (extended keys) is ignored.
    -- ---------------------------------------------------------------------
    process(clk)
        variable v_ascii : std_logic_vector(7 downto 0);
    begin
        if rising_edge(clk) then
            key_valid <= '0';

            if rst_int = '1' then
                kbd_break <= '0';
                kbd_ext   <= '0';
                kbd_held  <= '0';
            elsif ps2_byte_valid = '1' then
                if ps2_byte = x"F0" then
                    kbd_break <= '1';
                elsif ps2_byte = x"E0" then
                    kbd_ext <= '1';
                else
                    kbd_break <= '0';
                    kbd_ext   <= '0';
                    v_ascii := scan_to_ascii(ps2_byte);

                    if kbd_ext = '0' then
                        if kbd_break = '1' then
                            if ps2_byte = kbd_held_code then
                                kbd_held <= '0';          -- key released
                            end if;
                        elsif v_ascii /= x"00" then
                            if kbd_held = '0' or ps2_byte /= kbd_held_code then
                                key_valid     <= '1';     -- new key press
                                key_ascii     <= v_ascii;
                                kbd_held      <= '1';
                                kbd_held_code <= ps2_byte;
                            end if;                       -- else: typematic repeat, ignore
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    enter_evt  <= '1' when (key_valid = '1' and key_ascii = x"0D") or btn_pulse = '1' else '0';
    letter_evt <= '1' when (key_valid = '1' and key_ascii /= x"0D") else '0';

    -- ---------------------------------------------------------------------
    -- LFSR
    -- 8 bits, taps 8,6,5,4 (x^8 + x^6 + x^5 + x^4 + 1), maximal length: goes
    -- through all 255 non-zero values. All zeros would lock it, so the seed
    -- is A5. It runs all the time, so the value we grab when ENTER is pressed
    -- depends on the exact moment of the press.
    -- The 0..255 -> 0..29 conversion is done in S_NEW_GAME (subtract 30 until
    -- the value is below 30), so the index is always valid.
    -- ---------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_int = '1' then
                lfsr <= x"A5";
            else
                lfsr <= lfsr(6 downto 0) & (lfsr(7) xor lfsr(5) xor lfsr(4) xor lfsr(3));
            end if;
        end if;
    end process;

    -- ---------------------------------------------------------------------
    -- Word database (tables are declared above)
    -- ---------------------------------------------------------------------
    rom_word <= WORD_ROM(word_idx);
    rom_len  <= LEN_ROM(word_idx);

    -- ---------------------------------------------------------------------
    -- Game controller
    -- ---------------------------------------------------------------------
    process(clk)
        variable v_idx   : integer range 0 to 25;
        variable v_found : boolean;
        variable v_all   : boolean;
        variable v_rev   : std_logic_vector(MAX_WORD_LEN-1 downto 0);
    begin
        if rising_edge(clk) then
            if rst_int = '1' then
                game_state <= S_INIT;
            else
                case game_state is

                    when S_INIT =>
                        if lcd_ready = '1' then
                            game_state <= S_IDLE;
                        end if;

                    when S_IDLE =>
                        if enter_evt = '1' then
                            rand_val   <= to_integer(unsigned(lfsr));
                            game_state <= S_NEW_GAME;
                        end if;

                    when S_NEW_GAME =>
                        if rand_val >= NUM_WORDS then
                            rand_val <= rand_val - NUM_WORDS;
                        else
                            word_idx   <= rand_val;
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
                        if letter_evt = '1' then
                            v_idx := to_integer(unsigned(key_ascii)) - 65;   -- A = 0 ... Z = 25

                            -- repeated letters are ignored, no penalty
                            if used_letters(v_idx) = '0' then
                                used_letters(v_idx) <= '1';
                                last_letter         <= key_ascii;

                                -- reveal all matches and check if the word is complete
                                v_found := false;
                                v_all   := true;
                                v_rev   := revealed;
                                for i in 0 to MAX_WORD_LEN-1 loop
                                    if i < secret_len then
                                        if secret(i) = key_ascii then
                                            v_rev(i) := '1';
                                            v_found  := true;
                                        end if;
                                        if v_rev(i) = '0' then
                                            v_all := false;
                                        end if;
                                    end if;
                                end loop;
                                revealed <= v_rev;

                                if v_found then
                                    if v_all then
                                        game_state <= S_WIN;
                                    end if;
                                else
                                    error_cnt <= error_cnt + 1;
                                    if error_cnt = MAX_ERRORS - 1 then
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
                        game_state <= S_INIT;

                end case;
            end if;
        end if;
    end process;

    -- ---------------------------------------------------------------------
    -- LCD screen: this process only fills lcd_buf (32 chars) from the game
    -- state. The LCD FSM below keeps sending the buffer, so the game never
    -- waits for the display. States not listed keep the old screen.
    -- ---------------------------------------------------------------------
    process(clk)
        variable step : integer range 1 to 2;
    begin
        if rising_edge(clk) then
            blink_cnt <= blink_cnt + 1;

            case game_state is

                when S_IDLE =>
                    for i in 0 to 15 loop
                        lcd_buf(i)      <= chr(MSG_TITLE(i+1));
                        lcd_buf(16 + i) <= chr(MSG_PRESS(i+1));
                    end loop;

                when S_PLAYING =>
                    -- line 1: word with '_' on hidden letters. Up to 8 letters get a
                    -- space between them, bigger words would not fit in 16 columns.
                    if secret_len <= 8 then
                        step := 2;
                    else
                        step := 1;
                    end if;
                    for i in 0 to 15 loop
                        lcd_buf(i) <= x"20";
                    end loop;
                    for i in 0 to MAX_WORD_LEN-1 loop
                        if i < secret_len then
                            if revealed(i) = '1' then
                                lcd_buf(i * step) <= secret(i);
                            else
                                lcd_buf(i * step) <= chr('_');
                            end if;
                        end if;
                    end loop;
                    -- line 2: "ERROS: 0X/06 [L]"
                    for i in 0 to 15 loop
                        lcd_buf(16 + i) <= chr(MSG_ERRORS(i+1));
                    end loop;
                    lcd_buf(16 + 8)  <= std_logic_vector(to_unsigned(48 + error_cnt, 8));
                    lcd_buf(16 + 14) <= last_letter;

                when S_WIN =>
                    for i in 0 to 15 loop
                        lcd_buf(i)      <= chr(MSG_WIN(i+1));
                        lcd_buf(16 + i) <= chr(MSG_NEWGAME(i+1));
                    end loop;

                when S_LOSE =>
                    -- line 2 alternates between the answer and the restart hint
                    for i in 0 to 15 loop
                        lcd_buf(i) <= chr(MSG_LOSE(i+1));
                        if blink_cnt(26) = '0' then
                            lcd_buf(16 + i) <= chr(MSG_ANSWER(i+1));
                        else
                            lcd_buf(16 + i) <= chr(MSG_NEWGAME(i+1));
                        end if;
                    end loop;
                    if blink_cnt(26) = '0' then
                        for i in 0 to MAX_WORD_LEN-1 loop
                            if i < secret_len then
                                lcd_buf(16 + 5 + i) <= secret(i);
                            end if;
                        end loop;
                    end if;

                when others =>
                    null;

            end case;
        end if;
    end process;

    -- ---------------------------------------------------------------------
    -- LCD driver FSM (HD44780, 4-bit mode, write only)
    -- Steps (lcd_seq):
    --    0..3   init nibbles 3,3,3,2
    --    4      function set 0x28
    --    5      entry mode 0x06
    --    6      display on 0x0C
    --    7      clear 0x01
    --    8      cursor to line 1 (0x80)
    --    9..24  line 1 chars
    --    25     cursor to line 2 (0xC0)
    --    26..41 line 2 chars
    -- After step 41 it goes back to 8 and refreshes the screen forever.
    -- Each byte is sent as two nibbles: setup -> E pulse -> gap.
    -- ---------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_int = '1' then
                lcd_state <= L_POWER_ON;
                lcd_timer <= LCD_POWER_ON;
                lcd_seq   <= 0;
                lcd_ready <= '0';
                lcd_e     <= '0';
            else
                case lcd_state is

                    when L_POWER_ON =>
                        if lcd_timer = 0 then
                            lcd_state <= L_LOAD;
                        else
                            lcd_timer <= lcd_timer - 1;
                        end if;

                    -- choose byte, RS and wait time for the current step
                    when L_LOAD =>
                        lcd_phase_low <= '0';
                        lcd_nib_only  <= '0';
                        lcd_tx_rs     <= '0';
                        lcd_tx_wait   <= LCD_WAIT_50US;
                        if lcd_seq <= 3 then
                            lcd_nib_only <= '1';
                        end if;

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
                            when 3 =>
                                lcd_tx_byte <= x"20";             -- go to 4-bit mode
                                lcd_tx_wait <= LCD_WAIT_100US;
                            when 4 =>
                                lcd_tx_byte <= x"28";
                            when 5 =>
                                lcd_tx_byte <= x"06";
                            when 6 =>
                                lcd_tx_byte <= x"0C";
                            when 7 =>
                                lcd_tx_byte <= x"01";
                                lcd_tx_wait <= LCD_WAIT_2MS;      -- clear is slow
                            when 8 =>
                                lcd_tx_byte <= x"80";
                            when 9 to 24 =>
                                lcd_tx_rs   <= '1';
                                lcd_tx_byte <= lcd_buf(lcd_seq - 9);
                            when 25 =>
                                lcd_tx_byte <= x"C0";
                            when others =>
                                lcd_tx_rs   <= '1';
                                lcd_tx_byte <= lcd_buf(lcd_seq - 10);
                        end case;

                        lcd_timer <= 4;
                        lcd_state <= L_SETUP;

                    -- RS and data first, E still low (needs > 40 ns)
                    when L_SETUP =>
                        lcd_e  <= '0';
                        lcd_rs <= lcd_tx_rs;
                        if lcd_phase_low = '0' then
                            lcd_db <= lcd_tx_byte(7 downto 4);
                        else
                            lcd_db <= lcd_tx_byte(3 downto 0);
                        end if;
                        if lcd_timer = 0 then
                            lcd_timer <= 12;                      -- E high for 13 cycles = 260 ns
                            lcd_state <= L_E_HIGH;
                        else
                            lcd_timer <= lcd_timer - 1;
                        end if;

                    when L_E_HIGH =>
                        lcd_e <= '1';
                        if lcd_timer = 0 then
                            lcd_timer <= 50;                      -- ~1 us gap
                            lcd_state <= L_E_LOW;
                        else
                            lcd_timer <= lcd_timer - 1;
                        end if;

                    when L_E_LOW =>
                        lcd_e <= '0';
                        if lcd_timer = 0 then
                            if lcd_nib_only = '0' and lcd_phase_low = '0' then
                                lcd_phase_low <= '1';             -- now the low nibble
                                lcd_timer     <= 4;
                                lcd_state     <= L_SETUP;
                            else
                                lcd_timer <= lcd_tx_wait;
                                lcd_state <= L_WAIT;
                            end if;
                        else
                            lcd_timer <= lcd_timer - 1;
                        end if;

                    when L_WAIT =>
                        if lcd_timer = 0 then
                            if lcd_seq = 7 then
                                lcd_ready <= '1';                 -- clear done, init finished
                            end if;
                            if lcd_seq = LCD_LAST_STEP then
                                lcd_seq <= 8;
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
    end process;

    lcd_rw <= '0';

    -- ---------------------------------------------------------------------
    -- LEDs
    --   led(2..0) errors in binary (0 to 6)
    --   led(3)    playing
    --   led(4)    toggles on every key press (to check the keyboard)
    --   led(5)    LCD initialized
    --   led(6)    win
    --   led(7)    lose
    -- ---------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_int = '1' then
                key_led <= '0';
            elsif key_valid = '1' then
                key_led <= not key_led;
            end if;
        end if;
    end process;

    led(2 downto 0) <= std_logic_vector(to_unsigned(error_cnt, 3));
    led(3) <= '1' when game_state = S_PLAYING else '0';
    led(4) <= key_led;
    led(5) <= lcd_ready;
    led(6) <= '1' when game_state = S_WIN  else '0';
    led(7) <= '1' when game_state = S_LOSE else '0';

end Behavioral;
