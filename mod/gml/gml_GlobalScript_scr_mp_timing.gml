// DELTARUNE Multiplayer - starting things at the same moment in every game.
//
//  * Shared clock: every client works out the difference between its clock and the host's.
//  * Ready check: a game that reached a start point stops there and tells the host. The host
//    waits for everyone who is in the battle (never forever: see the time limits below).
//  * Timed start: the host then names a moment a little in the future on the shared clock, far
//    enough ahead for the message to reach everyone. Nobody starts when the message arrives;
//    everyone starts at that moment, so a slow connection doesn't start later than a fast one.
//
// Start points: the "!" horn of an encounter (mp_enc_gate), the battle itself (freeze until the
// host's first TURN_GO), each turn's hero actions and each turn's bullets (mp_phase_gate_check).
// New turns already wait at the turn barrier and now use a timed start too.
//
// A battle is frozen with mp_hold_start: the frame after a phase began, before any game code
// ran, every instance in the room is switched off and the last picture stays on screen. It works
// for every enemy in every chapter, whichever of the ~100 places in the game starts its bullets.
// (Stalling those places instead isn't safe: most of them create the bullet box just before.)

function mp_timing_init()
{
    global.mp_clock_off = 0;
    global.mp_clock_up = array_create(40, 0);
    global.mp_clock_down = array_create(40, 0);
    global.mp_clock_n = 0;
    global.mp_clock_i = 0;
    global.mp_prtt = array_create(8, 0);
    global.mp_hold = 0;
    global.mp_hold_want = 0;
    global.mp_hold_list = ds_list_create();
    global.mp_hold_snap = -1;
    global.mp_hold_since = 0;
    global.mp_hold_room = -1;
    global.mp_hold_kind = 0;
    global.mp_tgo_pending = -1;
    global.mp_enc_waiting = 0;
    global.mp_enc_since = 0;
    global.mp_enc_open = 0;
    global.mp_enc_open_since = 0;
    global.mp_enc_no = 0;
    global.mp_enc_ready = array_create(8, 0);
    global.mp_enc_go_at = 0;
    global.mp_enc_go_no = 0;
    global.mp_enc_go_time = -99999;
    global.mp_enc_go_unused = 0;
    global.mp_enc_declined = 0;
    global.mp_gate_rbid = array_create(8, -1);
    global.mp_gate_rkey = array_create(8, -1);
    mp_gate_reset();
}

function mp_gate_reset()
{
    global.mp_gate_key = -1;
    global.mp_gate_go_bid = -1;
    global.mp_gate_go_key = -1;
    global.mp_gate_go_at = 0;
    global.mp_gate_sent_key = -1;
    global.mp_gate_open_key = -1;
    global.mp_gate_since = 0;
    global.mp_gate_prev_my = 0;
    global.mp_gate_prev_mn = 0;
    global.mp_gate_done = -1;
    for (var i = 0; i < 8; i++)
    {
        global.mp_gate_rbid[i] = -1;
        global.mp_gate_rkey[i] = -1;
    }
}

// ---------------------------------------------------------------- shared clock

// The host's clock, in milliseconds.
function mp_clock_now()
{
    return current_time + global.mp_clock_off;
}

// From a ping's answer: sent = my clock when I pinged, host_t = the host's clock when it answered.
// Each way's delay also holds a wait for the other game's next frame (messages are only read once
// a frame). Those waits differ per direction, but as the two frame rhythms slide past each other
// each direction's shortest delay comes close to the pure network delay. So the shortest of each
// direction over the last 20 seconds gives a better answer than any single round trip.
function mp_clock_sample(sent, host_t)
{
    var now = current_time mod 4000000000;
    var i = global.mp_clock_i;
    global.mp_clock_up[i] = host_t - sent;
    global.mp_clock_down[i] = now - host_t;
    global.mp_clock_i = (i + 1) mod 40;
    global.mp_clock_n = min(global.mp_clock_n + 1, 40);
    var up = global.mp_clock_up[0];
    var down = global.mp_clock_down[0];
    for (var k = 1; k < global.mp_clock_n; k++)
    {
        up = min(up, global.mp_clock_up[k]);
        down = min(down, global.mp_clock_down[k]);
    }
    global.mp_clock_off = (up - down) / 2;
}

// How far ahead the host names a start: long enough for the message to reach the slowest player.
function mp_timing_lead()
{
    var worst = 0;
    var others = false;
    for (var i = 1; i < 8; i++)
    {
        if (global.mp_pconn[i])
        {
            others = true;
            worst = max(worst, global.mp_prtt[i]);
        }
    }
    if (!others)
        return 0;
    return clamp((worst * 0.75) + 70, 100, 900);
}

// True once the moment has come. In the last frame before it, waits out the remainder here, so
// the start lands on the moment itself instead of on whichever frame comes next (up to 33 ms off).
// Only ever called while the game is holding still, so the short wait can't be seen.
function mp_at_reached(at)
{
    var left = at - mp_clock_now();
    if (left <= 0)
        return true;
    if (left > 33)
        return false;
    var spin_end = get_timer() + (left * 1000);
    while (get_timer() < spin_end)
    {
    }
    return true;
}

// Logged when something starts, so tests can compare the moment between games.
function mp_sync_log(what)
{
    if (variable_global_exists("mp_test_ws"))
        mp_log("[MPSYNC] " + what + " wc=" + string_format(global.mp_test_ws - ((global.mp_test_wb - current_time) / 1000), 1, 3));
}

// ---------------------------------------------------------------- freezing

function mp_hold_start(kind)
{
    if (global.mp_hold)
    {
        global.mp_hold_kind = kind;
        return true;
    }
    if (!surface_exists(application_surface))
        return false;
    var w = surface_get_width(application_surface);
    var h = surface_get_height(application_surface);
    if (surface_exists(global.mp_hold_snap) && (surface_get_width(global.mp_hold_snap) != w || surface_get_height(global.mp_hold_snap) != h))
        surface_free(global.mp_hold_snap);
    if (!surface_exists(global.mp_hold_snap))
        global.mp_hold_snap = surface_create(w, h);
    surface_copy(global.mp_hold_snap, 0, 0, application_surface);
    ds_list_clear(global.mp_hold_list);
    // Persistent objects (the game's clock, music, this mod) keep running. Only what we switched
    // off is switched back on: the game has things of its own that it keeps switched off.
    with (all)
    {
        if (!persistent)
            ds_list_add(global.mp_hold_list, id);
    }
    for (var i = 0; i < ds_list_size(global.mp_hold_list); i++)
        instance_deactivate_object(ds_list_find_value(global.mp_hold_list, i));
    global.mp_hold = 1;
    global.mp_hold_kind = kind;
    global.mp_hold_since = current_time;
    global.mp_hold_room = room;
    mp_log("hold start kind=" + string(kind) + " froze=" + string(ds_list_size(global.mp_hold_list)));
    return true;
}

function mp_hold_end()
{
    if (!global.mp_hold)
        return;
    for (var i = 0; i < ds_list_size(global.mp_hold_list); i++)
        instance_activate_object(ds_list_find_value(global.mp_hold_list, i));
    ds_list_clear(global.mp_hold_list);
    global.mp_hold = 0;
    mp_log("hold end after " + string(current_time - global.mp_hold_since) + "ms");
}

// obj_mp_controller Draw: keeps the last picture on screen while everything else is switched off.
function mp_hold_draw()
{
    if (!global.mp_hold || !surface_exists(global.mp_hold_snap))
        return;
    var cam = view_camera[0];
    draw_surface_stretched(global.mp_hold_snap, camera_get_view_x(cam), camera_get_view_y(cam), camera_get_view_width(cam), camera_get_view_height(cam));
}

// Start of every frame, before any game code runs. True while the game stays frozen this frame.
function mp_timing_input()
{
    if (is_array(global.mp_tgo_pending) && mp_at_reached(global.mp_tgo_pending[18]))
    {
        var st = global.mp_tgo_pending;
        global.mp_tgo_pending = -1;
        mp_hold_end();
        mp_sync_log("turn" + string(st[1]));
        mp_apply_tgo(st);
    }
    if (global.mp_hold_want && global.mp_b_active && global.mp_bwait)
    {
        global.mp_hold_want = 0;
        mp_hold_start(0);
    }
    if (!global.mp_hold)
        return false;
    if (global.mp_hold_kind == 1)
    {
        var released = global.mp_gate_go_bid == global.mp_bid && global.mp_gate_go_key >= global.mp_gate_key && mp_at_reached(global.mp_gate_go_at);
        // The host never answered (it should always have by now): carry on rather than stay frozen.
        if (released || (current_time - global.mp_hold_since) > 30000)
        {
            if (!released)
                mp_log("phase gate gave up waiting for the host");
            mp_sync_log("phase" + string(global.mp_gate_key));
            global.mp_gate_done = global.mp_gate_key;
            mp_hold_end();
            return false;
        }
    }
    return true;
}

// obj_mp_controller Step while frozen: only the parts that don't need the room's instances.
function mp_hold_tick()
{
    if (!mp_on() || room != global.mp_hold_room || !global.mp_b_active)
    {
        mp_hold_end();
        return;
    }
    mp_host_turn_check();
    mp_gate_host_tick();
    mp_client_gate_fallback();
    if (global.mp_role == 1 && global.mp_bwait)
    {
        var bn = mp_bwait_names();
        if ((global.mp_frame mod 30) == 0 || bn != global.mp_bwait_names_sent)
        {
            global.mp_bwait_names_sent = bn;
            mp_begin(35);
            mp_wstr(bn);
            mp_send();
        }
    }
}

// ---------------------------------------------------------------- hero actions and bullets

// At the start of the frame after a phase began. True: this game now waits (frozen) for the others.
function mp_phase_gate_check()
{
    var kind = 0;
    if (global.mp_gate_prev_my == 0 && global.mnfight == 0 && global.myfight > 0 && global.myfight != 7)
        kind = 1;
    var is_bullets = global.mnfight == 1.5 || global.mnfight == 2;
    if (is_bullets && global.mp_gate_prev_mn != 1.5 && global.mp_gate_prev_mn != 2)
        kind = 2;
    global.mp_gate_prev_my = global.myfight;
    global.mp_gate_prev_mn = global.mnfight;
    if (kind == 0 || global.mp_bwait)
        return false;
    var key = (global.mp_bturn * 4) + kind;
    if (key <= global.mp_gate_done)
        return false;
    global.mp_gate_key = key;
    mp_begin(48);
    mp_wu16(global.mp_bid);
    mp_wu16(key);
    mp_send();
    if (global.mp_role == 1)
    {
        global.mp_gate_rbid[0] = global.mp_bid;
        global.mp_gate_rkey[0] = key;
    }
    // The host already said go (it stopped waiting for this game): just catch up.
    if (global.mp_gate_go_bid == global.mp_bid && global.mp_gate_go_key >= key && (global.mp_gate_go_at - mp_clock_now()) <= 0)
    {
        mp_sync_log("phase" + string(key));
        global.mp_gate_done = key;
        return false;
    }
    if (!mp_hold_start(1))
    {
        global.mp_gate_done = key;
        return false;
    }
    return true;
}

function mp_gate_missing_names()
{
    var k = global.mp_gate_open_key;
    var names = "";
    for (var i = 0; i < 8; i++)
    {
        if (global.mp_pconn[i] && mp_gate_waits_for(i, k))
        {
            if (names != "")
                names += ", ";
            names += global.mp_pname[i];
        }
    }
    return names;
}

// Host: does phase key k still have to wait for player i?
function mp_gate_waits_for(i, k)
{
    if (global.mp_gate_rbid[i] == global.mp_bid && global.mp_gate_rkey[i] >= k)
        return false;
    if (i != 0)
    {
        // Not in this battle, or joined late and enters at the next turn.
        if (global.mp_tdone_bid[i] != global.mp_bid || global.mp_tdone_late[i] || global.mp_tdone_turn[i] < floor(k / 4))
            return false;
        // Left the battle.
        if ((global.mp_pstate[i] & 1) == 0 && (current_time - global.mp_ppostime[i]) < 5000 && (current_time - global.mp_gate_since) > 3000)
            return false;
    }
    return true;
}

// Host: release a phase once everyone in the battle reached it. Someone who stays away (reading
// slowly, gone quiet) holds the others up for at most 15 seconds, and catches up when they get there.
function mp_gate_host_tick()
{
    if (global.mp_role != 1 || !global.mp_b_active)
        return;
    var k = -1;
    for (var i = 0; i < 8; i++)
    {
        if (global.mp_pconn[i] && global.mp_gate_rbid[i] == global.mp_bid)
            k = max(k, global.mp_gate_rkey[i]);
    }
    if (k <= global.mp_gate_sent_key)
        return;
    if (k != global.mp_gate_open_key)
    {
        global.mp_gate_open_key = k;
        global.mp_gate_since = current_time;
    }
    var names = mp_gate_missing_names();
    if (names != "" && (current_time - global.mp_gate_since) < 15000)
    {
        if ((global.mp_frame mod 30) == 0)
        {
            mp_begin(35);
            mp_wstr(names);
            mp_send();
        }
        global.mp_bwait_names = names;
        global.mp_bwait_names_time = current_time;
        return;
    }
    var at = mp_clock_now() + mp_timing_lead();
    global.mp_gate_sent_key = k;
    mp_begin(49);
    mp_wu16(global.mp_bid);
    mp_wu16(k);
    mp_wf64(at);
    mp_send();
    global.mp_gate_go_bid = global.mp_bid;
    global.mp_gate_go_key = k;
    global.mp_gate_go_at = at;
}

// ---------------------------------------------------------------- encounter start

// Prepended to obj_testoverworldenemy's Step while it is about to sound the "!" horn. Everyone
// who is touching or being pulled into this encounter stands still here until the timed start.
function mp_enc_gate()
{
    if (!mp_on())
        return true;
    if (!global.mp_enc_waiting)
    {
        global.mp_enc_waiting = 1;
        global.mp_enc_since = current_time;
        // Call the others over now: the battle scene itself only begins after the horn.
        if (!global.mp_battle_pulled && !global.mp_battle_seen && (global.mp_sstate == 0 || global.mp_sstate == 1))
        {
            global.mp_battle_seen = 1;
            mp_send_pull(1);
        }
        mp_enc_send_ready(1);
    }
    if (global.mp_enc_go_unused && (current_time - global.mp_enc_go_time) < 10000)
    {
        if (!mp_at_reached(global.mp_enc_go_at))
            return false;
        global.mp_enc_go_unused = 0;
        global.mp_enc_waiting = 0;
        // Two players touched different enemies at once: everyone fights the first one.
        global.encounterno = global.mp_enc_go_no;
        mp_sync_log("horn");
        return true;
    }
    if ((current_time - global.mp_enc_since) > 7000)
    {
        mp_log("encounter start: no answer from the host, going ahead");
        global.mp_enc_waiting = 0;
        return true;
    }
    return false;
}

// flag 1: I'm at the start point. 2: I can't come (title screen, for example).
function mp_enc_send_ready(flag)
{
    if (global.mp_role == 1)
    {
        mp_enc_host_ready(0, global.encounterno, flag);
        return;
    }
    mp_begin(50);
    mp_ws16(global.encounterno);
    mp_wu8(flag);
    mp_send();
}

function mp_enc_host_ready(i, enc, flag)
{
    if (!global.mp_enc_open)
    {
        if (flag == 2)
            return;
        // Arriving after the encounter already started (a late joiner): go straight away.
        if (mp_in_battle_scene() && !global.mp_enc_waiting)
        {
            mp_enc_send_go(enc);
            return;
        }
        global.mp_enc_open = 1;
        global.mp_enc_open_since = current_time;
        global.mp_enc_no = enc;
        for (var k = 0; k < 8; k++)
            global.mp_enc_ready[k] = 0;
    }
    global.mp_enc_ready[i] = flag;
}

function mp_enc_host_tick()
{
    if (global.mp_role != 1 || !global.mp_enc_open)
        return;
    if ((current_time - global.mp_enc_open_since) < 5000)
    {
        for (var i = 0; i < 8; i++)
        {
            if (global.mp_pconn[i] && !global.mp_enc_ready[i])
                return;
        }
    }
    global.mp_enc_open = 0;
    mp_enc_send_go(global.mp_enc_no);
}

function mp_enc_send_go(enc)
{
    var at = mp_clock_now() + mp_timing_lead();
    mp_begin(51);
    mp_ws16(enc);
    mp_wf64(at);
    mp_send();
    mp_enc_got_go(enc, at);
}

function mp_enc_got_go(enc, at)
{
    global.mp_enc_go_no = enc;
    global.mp_enc_go_at = at;
    global.mp_enc_go_time = current_time;
    global.mp_enc_go_unused = 1;
}

function mp_timing_recv(type, from, b)
{
    if (type == 48) // reached a phase
    {
        var bid = buffer_read(b, buffer_u16);
        var key = buffer_read(b, buffer_u16);
        if (global.mp_role == 1 && from >= 0 && from < 8)
        {
            global.mp_gate_rbid[from] = bid;
            global.mp_gate_rkey[from] = key;
        }
        return;
    }
    if (type == 49) // phase: start at this moment
    {
        var bid2 = buffer_read(b, buffer_u16);
        var key2 = buffer_read(b, buffer_u16);
        var at = buffer_read(b, buffer_f64);
        global.mp_gate_go_bid = bid2;
        global.mp_gate_go_key = key2;
        global.mp_gate_go_at = at;
        return;
    }
    if (type == 50) // reached (or can't come to) an encounter
    {
        var enc = buffer_read(b, buffer_s16);
        var flag = buffer_read(b, buffer_u8);
        if (global.mp_role == 1 && from >= 0 && from < 8)
            mp_enc_host_ready(from, enc, flag);
        return;
    }
    if (type == 51) // encounter: start at this moment
    {
        var enc2 = buffer_read(b, buffer_s16);
        var at2 = buffer_read(b, buffer_f64);
        mp_enc_got_go(enc2, at2);
        return;
    }
}

// What the status line says while frozen. Nothing for a short wait: it would flash up every turn.
function mp_timing_status()
{
    if (global.mp_enc_waiting && (current_time - global.mp_enc_since) > 800)
        return "Waiting for other players to join the battle...";
    if (global.mp_hold && (current_time - global.mp_hold_since) > 800)
    {
        var names = mp_bwait_names();
        if (names != "")
            return "Waiting for " + names + "...";
        return "Waiting for other players...";
    }
    return "";
}
