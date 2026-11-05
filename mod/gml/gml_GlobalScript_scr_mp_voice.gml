// DELTARUNE Multiplayer - proximity voice chat.
//
// The microphone gives 16 kHz 16-bit mono. That goes out as 8 kHz mu-law (8 KB/s while talking, like
// a phone call), in 40 ms packets. Packets skip the reliable queue: a late voice packet is useless,
// and a lost one is a tiny gap. Players only hear each other in the same room, quieter with distance.
//
// The microphone is only open while you are talking (held V) or when you chose open mic, and it
// never opens at all with voice chat set to off.

function mp_voice_init()
{
    global.mp_v_rec = -1;
    global.mp_v_talking = 0;
    global.mp_v_seq = 0;
    global.mp_v_out = buffer_create(1024, buffer_fixed, 1);
    global.mp_v_outn = 0;
    global.mp_v_carry = 0;
    global.mp_v_hascarry = false;
    global.mp_v_energy = 0;
    global.mp_v_level = 0;
    global.mp_v_gate_until = 0;
    global.mp_v_test = 0;
    global.mp_v_nomic_told = 0;
    global.mp_v_tone = 0;
    global.mp_v_tonebuf = -1;
    global.mp_v_q = array_create(8, -1);
    global.mp_v_inst = array_create(8, -1);
    global.mp_v_queued = array_create(8, 0);
    global.mp_v_last = array_create(8, -99999);
    global.mp_v_rx = array_create(8, 0);
    global.mp_v_lastseq = array_create(8, -1);
    global.mp_v_bufs = ds_map_create();
    global.mp_v_exp = array_create(256, 0);
    for (var i = 1; i < 256; i++)
        global.mp_v_exp[i] = floor(log2(i));
    global.mp_v_dec = array_create(256, 0);
    for (var u = 0; u < 256; u++)
    {
        var inv = (~u) & 255;
        var t = ((inv & 15) << 3) + 132;
        t = t << ((inv & 112) >> 4);
        global.mp_v_dec[u] = (inv & 128) ? (132 - t) : (t - 132);
    }
}

function mp_voice_encode(s)
{
    var sign = 0;
    if (s < 0)
    {
        s = -s;
        sign = 128;
    }
    s = min(s, 32635) + 132;
    var e = global.mp_v_exp[(s >> 7) & 255];
    var m = (s >> (e + 3)) & 15;
    return (~(sign | (e << 4) | m)) & 255;
}

// ---------------------------------------------------------------- microphone

function mp_voice_mic_on()
{
    if (global.mp_v_rec >= 0)
        return;
    var n = audio_get_recorder_count();
    if (n <= 0)
    {
        if (!global.mp_v_nomic_told)
        {
            global.mp_v_nomic_told = 1;
            mp_notify("No microphone found.");
        }
        return;
    }
    global.mp_v_rec = audio_start_recording(clamp(global.mp_cfg_vmic, 0, n - 1));
}

function mp_voice_mic_off()
{
    if (global.mp_v_rec < 0)
        return;
    audio_stop_recording(global.mp_v_rec);
    global.mp_v_rec = -1;
    global.mp_v_outn = 0;
    global.mp_v_energy = 0;
    global.mp_v_hascarry = false;
}

// The microphone's name, for the settings page.
function mp_voice_mic_name()
{
    var n = audio_get_recorder_count();
    if (n <= 0)
        return "none found";
    var info = audio_get_recorder_info(clamp(global.mp_cfg_vmic, 0, n - 1));
    if (!ds_exists(info, ds_type_map))
        return "Microphone " + string(global.mp_cfg_vmic + 1);
    var nm = ds_map_find_value(info, "name");
    ds_map_destroy(info);
    if (is_undefined(nm))
        return "Microphone " + string(global.mp_cfg_vmic + 1);
    return string_copy(nm, 1, 28);
}

// obj_mp_controller Async - Audio Recording.
function mp_voice_recorded()
{
    if (global.mp_v_rec < 0 || ds_map_find_value(async_load, "channel_index") != global.mp_v_rec)
        return;
    mp_voice_feed(ds_map_find_value(async_load, "buffer_id"), 0, ds_map_find_value(async_load, "data_len"));
}

// 16 kHz samples in, 8 kHz mu-law packets out.
function mp_voice_feed(b, off, bytes)
{
    var gain = global.mp_cfg_vmicvol / 100;
    var i = off;
    var stop = off + bytes - 1;
    while (i < stop)
    {
        var s = buffer_peek(b, i, buffer_s16) * gain;
        i += 2;
        if (!global.mp_v_hascarry)
        {
            global.mp_v_carry = s;
            global.mp_v_hascarry = true;
            continue;
        }
        global.mp_v_hascarry = false;
        var m = clamp((s + global.mp_v_carry) / 2, -32768, 32767);
        global.mp_v_energy += abs(m);
        buffer_poke(global.mp_v_out, global.mp_v_outn, buffer_u8, mp_voice_encode(round(m)));
        global.mp_v_outn += 1;
        if (global.mp_v_outn >= 320)
            mp_voice_packet();
    }
}

function mp_voice_packet()
{
    var n = global.mp_v_outn;
    global.mp_v_outn = 0;
    var avg = global.mp_v_energy / n;
    global.mp_v_energy = 0;
    global.mp_v_level = max(avg, global.mp_v_level * 0.7);
    // Mic test: hear myself, nothing leaves this game.
    if (global.mp_v_test)
    {
        mp_voice_play(global.mp_myid, global.mp_v_out, 0, n);
        return;
    }
    // Open mic: only while there's something to hear, and a moment after, so words aren't cut off.
    if (global.mp_cfg_vmode == 2)
    {
        if (avg > mp_voice_gate_level())
            global.mp_v_gate_until = current_time + 400;
        if (current_time > global.mp_v_gate_until)
            return;
    }
    if (!mp_on())
        return;
    global.mp_v_seq = (global.mp_v_seq + 1) mod 65536;
    mp_voice_send(global.mp_myid, global.mp_v_seq, global.mp_v_out, 0, n);
    global.mp_v_last[global.mp_myid] = current_time;
}

// ---------------------------------------------------------------- network

function mp_voice_peer_send(p, from, seq, src, off, n)
{
    mp_pkt_begin(p);
    var pk = global.mp_pkt;
    buffer_write(pk, buffer_u8, 3);
    buffer_write(pk, buffer_u16, 0);
    buffer_write(pk, buffer_u16, n + 3);
    buffer_write(pk, buffer_u8, from);
    buffer_write(pk, buffer_u16, seq);
    buffer_copy(src, off, n, pk, buffer_tell(pk));
    buffer_seek(pk, buffer_seek_relative, n);
    mp_pkt_send(p);
}

// To the host; the host passes it on only to players in the same room, which saves everyone's
// connection and means a voice can't be picked up from anywhere else.
function mp_voice_send(from, seq, src, off, n)
{
    if (global.mp_role == 2)
    {
        if (is_struct(global.mp_hub))
            mp_voice_peer_send(global.mp_hub, from, seq, src, off, n);
        return;
    }
    var k = ds_map_find_first(global.mp_peers);
    while (!is_undefined(k))
    {
        var p = ds_map_find_value(global.mp_peers, k);
        k = ds_map_find_next(global.mp_peers, k);
        if (p.pid >= 0 && p.pid != from && global.mp_proom[p.pid] == mp_voice_room_of(from))
            mp_voice_peer_send(p, from, seq, src, off, n);
    }
}

function mp_voice_room_of(pid)
{
    return pid == global.mp_myid ? room : global.mp_proom[pid];
}

// Called from the network layer with a voice record.
function mp_voice_net(b, pos, len)
{
    if (len < 4)
        return;
    var from = buffer_peek(b, pos, buffer_u8);
    var seq = buffer_peek(b, pos + 1, buffer_u16);
    if (from >= 8 || from == global.mp_myid)
        return;
    var n = len - 3;
    if (global.mp_role == 1)
        mp_voice_send(from, seq, b, pos + 3, n);
    if (global.mp_cfg_vmode == 0 || global.mp_proom[from] != room)
        return;
    global.mp_v_last[from] = current_time;
    global.mp_v_rx[from] += 1;
    mp_voice_play(from, b, pos + 3, n);
}

// ---------------------------------------------------------------- playing

function mp_voice_play(pid, src, off, n)
{
    // Falling behind: drop this packet rather than fall further behind.
    if (global.mp_v_queued[pid] > 4000)
        return;
    if (global.mp_v_q[pid] < 0)
        global.mp_v_q[pid] = audio_create_play_queue(buffer_s16, 8000, audio_mono);
    var bb = buffer_create(n * 2, buffer_fixed, 2);
    for (var i = 0; i < n; i++)
        buffer_poke(bb, i * 2, buffer_s16, global.mp_v_dec[buffer_peek(src, off + i, buffer_u8)]);
    audio_queue_sound(global.mp_v_q[pid], bb, 0, n * 2);
    ds_map_set(global.mp_v_bufs, bb, pid);
    global.mp_v_queued[pid] += n;
    // A little in hand before starting, to ride out uneven arrival.
    if (global.mp_v_inst[pid] < 0 || !audio_is_playing(global.mp_v_inst[pid]))
    {
        if (global.mp_v_queued[pid] >= 960)
        {
            global.mp_v_inst[pid] = audio_play_sound(global.mp_v_q[pid], 100, false);
            audio_sound_gain(global.mp_v_inst[pid], mp_voice_gain(pid), 0);
        }
    }
}

// obj_mp_controller Async - Audio Playback: that piece has been played.
function mp_voice_played()
{
    var bb = ds_map_find_value(async_load, "buffer_id");
    if (is_undefined(bb) || !ds_map_exists(global.mp_v_bufs, bb))
        return;
    var pid = ds_map_find_value(global.mp_v_bufs, bb);
    ds_map_delete(global.mp_v_bufs, bb);
    global.mp_v_queued[pid] = max(0, global.mp_v_queued[pid] - (buffer_get_size(bb) / 2));
    buffer_delete(bb);
}

// Open mic: how loud I have to be for it to send. Low sensitivity needs more.
function mp_voice_gate_level()
{
    var levels = [1500, 500, 150];
    return levels[clamp(global.mp_cfg_vsens, 0, 2)];
}

function mp_voice_sens_name()
{
    var names = ["Low", "Normal", "High"];
    return names[clamp(global.mp_cfg_vsens, 0, 2)];
}

// What to call a key on screen.
function mp_key_name(k)
{
    if ((k >= ord("A") && k <= ord("Z")) || (k >= ord("0") && k <= ord("9")))
        return chr(k);
    switch (k)
    {
        case vk_space: return "Space";
        case vk_tab: return "Tab";
        case vk_lalt: return "Left Alt";
        case vk_ralt: return "Right Alt";
        case vk_alt: return "Alt";
        case vk_home: return "Home";
        case vk_end: return "End";
        case vk_insert: return "Insert";
        case vk_delete: return "Delete";
        case vk_pageup: return "Page Up";
        case vk_pagedown: return "Page Down";
        case vk_backspace: return "Backspace";
        case vk_f1: return "F1";
        case vk_f2: return "F2";
        case vk_f3: return "F3";
        case vk_f4: return "F4";
        case vk_f5: return "F5";
        case vk_f10: return "F10";
        case vk_f11: return "F11";
        case vk_f12: return "F12";
    }
    return "Key " + string(k);
}

// Keys the game or this mod already use can't be the talk key.
function mp_key_allowed(k)
{
    if (k == ord("Z") || k == ord("X") || k == ord("C"))
        return false;
    switch (k)
    {
        case vk_left: case vk_right: case vk_up: case vk_down:
        case vk_enter: case vk_shift: case vk_lshift: case vk_rshift:
        case vk_control: case vk_lcontrol: case vk_rcontrol: case vk_escape:
        case vk_f6: case vk_f7: case vk_f8: case vk_f9:
            return false;
    }
    return true;
}

// How loud a player is for me.
function mp_voice_gain(pid)
{
    var vol = global.mp_cfg_vvol / 100;
    if (pid == global.mp_myid)
        return vol;
    if (!global.mp_pconn[pid] || global.mp_proom[pid] != room)
        return 0;
    var range = mp_voice_range();
    if (range <= 0)
        return vol; // the whole room
    var d = point_distance(global.mp_my_x, global.mp_my_y, global.mp_px[pid], global.mp_py[pid]);
    return vol * clamp(1 - ((d - (range * 0.25)) / (range * 0.75)), 0, 1);
}

// How far a voice carries: one screen is 640 wide. 0 is the whole room.
function mp_voice_range()
{
    var ranges = [320, 640, 1280, 0];
    return ranges[clamp(global.mp_cfg_vrange, 0, 3)];
}

function mp_voice_range_name()
{
    var names = ["Short", "Normal", "Far", "Whole room"];
    return names[clamp(global.mp_cfg_vrange, 0, 3)];
}

function mp_voice_speaking(pid)
{
    return (current_time - global.mp_v_last[pid]) < 400;
}

// ---------------------------------------------------------------- every frame

function mp_voice_tick()
{
    var editing = global.mp_ui_edit >= 0 || global.mp_ui_bind;
    var want = global.mp_v_test;
    if (!want && mp_on() && !editing)
    {
        if (global.mp_cfg_vmode == 1 && keyboard_check(global.mp_cfg_vkey))
            want = true;
        if (global.mp_cfg_vmode == 2)
            want = true;
    }
    global.mp_v_talking = want && !global.mp_v_test && (global.mp_cfg_vmode == 1 || current_time <= global.mp_v_gate_until);
    if (want)
        mp_voice_mic_on();
    else
        mp_voice_mic_off();
    mp_voice_test_tone();
    if ((global.mp_frame mod 5) != 0)
        return;
    global.mp_v_level *= 0.8;
    for (var i = 0; i < 8; i++)
    {
        var inst = global.mp_v_inst[i];
        if (inst >= 0 && audio_is_playing(inst))
            audio_sound_gain(inst, mp_voice_gain(i), 150);
    }
}

// Tests: a tone stands in for the microphone (tests never open the real one).
function mp_voice_test_tone()
{
    if (global.mp_test == "" || !mp_test_has("voicetone") || !mp_on())
        return;
    if (global.mp_v_tonebuf < 0)
        global.mp_v_tonebuf = buffer_create(2134, buffer_fixed, 2);
    for (var i = 0; i < 533; i++)
    {
        global.mp_v_tone += 1;
        buffer_poke(global.mp_v_tonebuf, i * 2, buffer_s16, round(sin(global.mp_v_tone * 0.1727) * 2500));
    }
    mp_voice_feed(global.mp_v_tonebuf, 0, 1066);
    if ((global.mp_frame mod 150) == 0)
        mp_log("[voicetest] sent=" + string(global.mp_v_seq) + " rx=" + string(global.mp_v_rx[0]) + "/" + string(global.mp_v_rx[1]) + " queued=" + string(global.mp_v_queued[0]) + "/" + string(global.mp_v_queued[1]) + " playing=" + string(global.mp_v_inst[0] >= 0 && audio_is_playing(global.mp_v_inst[0])) + "/" + string(global.mp_v_inst[1] >= 0 && audio_is_playing(global.mp_v_inst[1])) + " gain=" + string_format(mp_voice_gain(global.mp_myid == 0 ? 1 : 0), 1, 2) + " fps=" + string(fps));
}
