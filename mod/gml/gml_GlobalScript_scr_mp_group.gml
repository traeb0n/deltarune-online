// DELTARUNE Multiplayer - who is in which fight.
//
// Every fight has an id (gid) and a leader, the player who started it. Battle messages carry the
// gid, and a game only listens to its own fight, so any number of fights can run at once. The
// leader does what only one game may do: releases turns and phases, decides who plays which hero.
// If the leader goes, the lowest-numbered player left in the fight takes over.
//
// The host's setting (global.mp_open):
//  * Open-world battles: touching an enemy brings in the players on screen with you. You fight
//    with only the heroes of the players in your fight. Anyone else can walk up to a fighting
//    player and press Z, and enters at the next player turn. Story battles still bring in everyone.
//  * Everyone gets pulled in: every battle is every player's.

function mp_group_init()
{
    global.mp_open = global.mp_cfg_open;
    global.mp_gid = 0;
    global.mp_gid_seq = 0;
    global.mp_b_leader = 0;
    global.mp_b_mask = 255;
    global.mp_b_story = 0;
    global.mp_b_open = global.mp_open;
    global.mp_party_local = 0;
    global.mp_party_story = [0, 0, 0];
    global.mp_pull_mask = -1;
    global.mp_snap_gold = 0;
    global.mp_snap_item = -1;
    global.mp_snap_hp = array_create(5, 0);
    global.mp_snap_valid = 0;
    global.mp_item_used = -1;
    global.mp_item_gained = -1;
    global.mp_wipe = 0;
    global.mp_wipe_room = -1;
    global.mp_wipe_x = 0;
    global.mp_wipe_y = 0;
    global.mp_entry_x = 0;
    global.mp_entry_y = 0;
    global.mp_entry_room = -1;
    global.mp_join_target = -1;
    global.mp_join_asked = -99999;
    global.mp_my_touch = "";
}

function mp_b_lead()
{
    return global.mp_gid != 0 && global.mp_b_leader == global.mp_myid;
}

function mp_in_mask(i)
{
    return ((global.mp_b_mask >> i) & 1) != 0;
}

// Starts a new fight led by me, unless I'm already in one.
function mp_gid_ensure(mask, story)
{
    if (global.mp_gid != 0)
        return;
    global.mp_gid_seq = (global.mp_gid_seq mod 4095) + 1; // (never 0: a fight's id is never 0)
    global.mp_gid = (global.mp_myid << 12) | global.mp_gid_seq;
    global.mp_b_leader = global.mp_myid;
    global.mp_b_mask = mask | (1 << global.mp_myid);
    global.mp_b_story = story;
    global.mp_b_open = global.mp_open;
    mp_log("fight " + string(global.mp_gid) + " started, mask=" + string(global.mp_b_mask) + " story=" + string(story));
}

function mp_gid_clear()
{
    global.mp_gid = 0;
    global.mp_b_mask = 255;
    global.mp_b_story = 0;
}

// Message header for everything that belongs to a fight.
function mp_begin_b(type)
{
    mp_begin(type);
    mp_wu16(global.mp_gid);
}

// (A fight keeps the rules it started with if the host changes the setting meanwhile.)
function mp_open_fight()
{
    return (global.mp_gid != 0 ? global.mp_b_open : global.mp_open) && !global.mp_b_story;
}

// ---------------------------------------------------------------- who is nearby

// Other players on my screen, in my room, and free to fight.
function mp_nearby_mask()
{
    var m = 1 << global.mp_myid;
    var cam = view_camera[0];
    var cx = camera_get_view_x(cam);
    var cy = camera_get_view_y(cam);
    var cw = camera_get_view_width(cam);
    var ch = camera_get_view_height(cam);
    for (var i = 0; i < 8; i++)
    {
        if (i == global.mp_myid || !global.mp_pconn[i] || global.mp_proom[i] != room)
            continue;
        if ((global.mp_pstate[i] & 3) != 0) // in a fight or a cutscene
            continue;
        if (global.mp_px[i] >= cx && global.mp_px[i] <= (cx + cw) && global.mp_py[i] >= cy && global.mp_py[i] <= (cy + ch))
            m |= (1 << i);
    }
    return m;
}

// A player already fighting on my screen, or -1.
function mp_nearby_fight()
{
    var cam = view_camera[0];
    var cx = camera_get_view_x(cam);
    var cy = camera_get_view_y(cam);
    var cw = camera_get_view_width(cam);
    var ch = camera_get_view_height(cam);
    for (var i = 0; i < 8; i++)
    {
        if (i == global.mp_myid || !global.mp_pconn[i] || global.mp_proom[i] != room || (global.mp_pstate[i] & 1) == 0)
            continue;
        if (global.mp_px[i] >= cx && global.mp_px[i] <= (cx + cw) && global.mp_py[i] >= cy && global.mp_py[i] <= (cy + ch))
            return i;
    }
    return -1;
}

// ---------------------------------------------------------------- the party of a fight

function mp_hero_ok(c)
{
    // (Chapter 1's stats have no slot for Noelle.)
    if (c < 1 || c >= array_length(global.maxhp) || c >= array_length(global.hp))
        return false;
    var nm = ["", "obj_herokris", "obj_herosusie", "obj_heroralsei", "obj_heronoelle"];
    return asset_get_index(nm[c]) >= 0 && global.maxhp[c] > 0;
}

// The heroes of the players in mask, Kris first (he comes first in the game's own parties).
function mp_party_of(mask)
{
    var party = [0, 0, 0];
    var n = 0;
    for (var c = 1; c <= 4 && n < 3; c++)
    {
        for (var i = 0; i < 8; i++)
        {
            if (((mask >> i) & 1) && global.mp_pconn[i] && global.mp_pchar[i] == c && mp_hero_ok(c))
            {
                party[n] = c;
                n += 1;
                break;
            }
        }
    }
    // A hero this chapter has no stats for: play whoever the story has first.
    if (n == 0)
    {
        for (var s = 0; s < 3 && n == 0; s++)
        {
            if (global.char[s] != 0)
            {
                party[0] = global.char[s];
                n = 1;
            }
        }
    }
    return party;
}

// Fights have their own party; the story's stays as it was. Shared-state sync is off meanwhile
// (mp_vars_can_sync), so the fight's party never reaches the other players.
function mp_party_set_local(party)
{
    if (!global.mp_party_local)
    {
        global.mp_party_local = 1;
        global.mp_party_story = [global.char[0], global.char[1], global.char[2]];
    }
    for (var s = 0; s < 3; s++)
    {
        global.char[s] = party[s];
        if (party[s] != 0 && global.hp[party[s]] <= 0)
            global.hp[party[s]] = ceil(global.maxhp[party[s]] / 2);
    }
}

function mp_party_restore()
{
    if (!global.mp_party_local)
        return;
    global.mp_party_local = 0;
    for (var s = 0; s < 3; s++)
        global.char[s] = global.mp_party_story[s];
}

// Battle's Create left the heroes where they stand for the old party size.
function mp_heroes_place()
{
    var total = 0;
    for (var s = 0; s < 3; s++)
    {
        if (global.char[s] != 0)
            total += 1;
    }
    var yy = camera_get_view_y(view_camera[0]);
    for (var i = 0; i < 3; i++)
    {
        if (global.char[i] == 0)
            continue;
        var hy = yy + 50 + (80 * i);
        if (total == 1)
            hy = yy + 140;
        if (total == 2)
            hy = yy + 100 + (80 * i);
        global.heromakey[i] = hy;
        var h = global.charinstance[i];
        if (instance_exists(h))
        {
            h.y = hy;
            h.ystart = hy;
        }
    }
}

// The game assumes Kris is in every battle (the SOUL starts from him, for one: over a hundred places
// per chapter). A fight without him gets an invisible stand-in. Heroes only act through their Draw
// event, so one that isn't drawn does nothing but be there.
function mp_stand_in_make()
{
    if (instance_exists(obj_herokris))
        return;
    var k = instance_create(global.heromakex[0], global.heromakey[0], obj_herokris);
    k.myself = 0;
    k.char = 1;
    k.visible = 0;
    global.mp_stand_in = k;
    mp_log("stand-in Kris for this fight");
}

// Whatever the game does to its heroes, this one stays out of sight.
function mp_stand_in_tick()
{
    if (variable_global_exists("mp_stand_in") && instance_exists(global.mp_stand_in))
    {
        with (global.mp_stand_in)
        {
            visible = 0;
            x = global.heromakex[0];
            y = global.heromakey[0];
        }
    }
}

// The battle intro's markers: Kris's jump is hard-wired as the first figure, and every follower gets one.
function mp_intro_markers()
{
    if (!mp_on() || !mp_party_local_on())
        return;
    if (global.char[0] != 1)
    {
        var nm = global.char[0] == 2 ? "spr_susier_wall" : (global.char[0] == 3 ? "spr_ralsei_battleintro" : "spr_noelleb_battleintro");
        var sp = asset_get_index(nm);
        if (sp >= 0 && instance_exists(c[0]))
            c[0].sprite_index = sp;
    }
    while (count > 0 && global.char[count] == 0)
    {
        with (c[count])
            instance_destroy();
        count -= 1;
    }
}

// The battle's end, in obj_endbattle: the figures that walk back to the party. The game always sends
// Kris from the first slot and a follower from every slot; a fight with its own party has other
// heroes and empty slots. My hero walks back to my figure, the others to the followers.
function mp_end_markers()
{
    if (!mp_on() || !mp_party_local_on() || !(global.specialbattle == 0 || global.specialbattle == 3) || !instance_exists(obj_mainchara))
        return;
    var mine = global.mp_pchar[global.mp_myid];
    var order = [];
    for (var a = 0; a < 3; a++)
    {
        if (global.char[a] != 0 && global.char[a] == mine)
            array_push(order, a);
    }
    for (var b = 0; b < 3; b++)
    {
        if (global.char[b] != 0 && global.char[b] != mine)
            array_push(order, b);
    }
    for (var i = 0; i <= count; i++)
    {
        var m = c[i];
        if (!instance_exists(m))
            continue;
        var dest = i == 0 ? obj_mainchara : global.cinstance[i - 1];
        if (i >= array_length(order) || !instance_exists(dest))
        {
            with (m)
                instance_destroy();
            continue;
        }
        var s = order[i];
        var spr = mp_walk_sprite(global.char[s], "r");
        if (spr >= 0)
            m.sprite_index = spr;
        m.x = global.heromakex[s];
        m.y = global.heromakey[s];
        if (instance_exists(global.charinstance[s]))
        {
            m.x = global.charinstance[s].x;
            m.y = global.charinstance[s].y;
        }
        m.direction = point_direction(m.x, m.y, dest.x, dest.y);
        m.speed = point_distance(m.x, m.y, dest.x, dest.y) / 10;
    }
    mp_log("end markers: " + string(array_length(order)) + " heroes, " + string(count + 1) + " markers");
}

function mp_party_local_on()
{
    return global.mp_party_local;
}

// A player walked up and joined: their hero steps into the fight, in every game of that fight.
function mp_battle_add_hero(slot, c)
{
    var nm = ["", "obj_herokris", "obj_herosusie", "obj_heroralsei", "obj_heronoelle"];
    var obj = asset_get_index(nm[c]);
    if (obj < 0 || !instance_exists(obj_battlecontroller))
        return;
    mp_log("hero " + string(c) + " joins the fight in slot " + string(slot));
    if (c == 1 && variable_global_exists("mp_stand_in") && instance_exists(global.mp_stand_in))
    {
        with (global.mp_stand_in)
            instance_destroy();
    }
    global.char[slot] = c;
    global.charmove[slot] = 1;
    global.charcantarget[slot] = 1;
    global.chardead[slot] = 0;
    global.charcond[slot] = 0;
    global.automiss[slot] = 0;
    global.acting[slot] = 0;
    global.charaction[slot] = 0;
    global.chartarget[slot] = 0;
    global.battleat[slot] = global.at[c] + global.itemat[c][0] + global.itemat[c][1] + global.itemat[c][2];
    global.battledf[slot] = global.df[c] + global.itemdf[c][0] + global.itemdf[c][1] + global.itemdf[c][2];
    global.battlemag[slot] = global.mag[c] + global.itemmag[c][0] + global.itemmag[c][1] + global.itemmag[c][2];
    if (global.hp[c] <= 0)
        global.hp[c] = ceil(global.maxhp[c] / 2);
    var inst = instance_create(camera_get_view_x(view_camera[0]) + 80, 0, obj);
    inst.myself = slot;
    inst.char = c;
    inst.depth = 200 - (slot * 20);
    global.charinstance[slot] = inst;
    with (obj_battlecontroller)
    {
        chartotal = 0;
        for (var i = 0; i < 3; i++)
        {
            if (global.char[i] != 0)
                chartotal += 1;
        }
        charpos[c - 1] = slot;
        havechar[c - 1] = 1;
    }
    mp_heroes_place();
}

// Leader, before releasing a turn: heroes of players who joined since the last one.
function mp_party_grow()
{
    if (!mp_open_fight())
        return;
    for (var i = 0; i < 8; i++)
    {
        if (!global.mp_pconn[i] || !mp_in_mask(i) || global.mp_tdone_bid[i] != global.mp_bid)
            continue;
        var c = global.mp_pchar[i];
        if (!mp_hero_ok(c))
            continue;
        var free = -1;
        var have = false;
        for (var s = 2; s >= 0; s--)
        {
            if (global.char[s] == c)
                have = true;
            if (global.char[s] == 0)
                free = s;
        }
        if (!have && free >= 0)
            mp_battle_add_hero(free, c);
    }
}

// ---------------------------------------------------------------- what a fight changes

// Every game of a fight counts its victory and its items: only the leader's result stands, or a
// fight's gold would count once per player. A hero someone else plays isn't mine to report either.
function mp_fight_snapshot()
{
    global.mp_snap_valid = 1;
    global.mp_snap_gold = global.gold;
    global.mp_snap_item = array_create(array_length(global.item), 0);
    array_copy(global.mp_snap_item, 0, global.item, 0, array_length(global.item));
    for (var c = 1; c < array_length(global.hp) && c <= 4; c++)
        global.mp_snap_hp[c] = global.hp[c];
}

function mp_fight_settle(was_leader)
{
    if (!global.mp_snap_valid)
        return;
    global.mp_snap_valid = 0;
    var open = mp_open_fight();
    for (var c = 1; c < array_length(global.hp) && c <= 4; c++)
    {
        if (open && c != global.mp_pchar[global.mp_myid])
            global.hp[c] = global.mp_snap_hp[c];
    }
    var now = array_create(array_length(global.item), 0);
    array_copy(now, 0, global.item, 0, array_length(global.item));
    // Back to where the fight began, then the leader's changes on top of whatever others did.
    array_copy(global.item, 0, global.mp_snap_item, 0, array_length(global.mp_snap_item));
    if (!was_leader)
    {
        global.gold = global.mp_snap_gold;
        return;
    }
    var used = [];
    var gained = [];
    var left = array_create(array_length(global.mp_snap_item), 0);
    array_copy(left, 0, global.mp_snap_item, 0, array_length(global.mp_snap_item));
    for (var i = 0; i < array_length(now); i++)
    {
        if (now[i] == 0)
            continue;
        var found = false;
        for (var k = 0; k < array_length(left); k++)
        {
            if (left[k] == now[i])
            {
                left[k] = 0;
                found = true;
                break;
            }
        }
        if (!found)
            array_push(gained, now[i]);
    }
    for (var u = 0; u < array_length(left); u++)
    {
        if (left[u] != 0)
            array_push(used, left[u]);
    }
    global.mp_item_used = used;
    global.mp_item_gained = gained;
}

// After changes from other fights were applied: my fight's used and found items.
function mp_items_apply()
{
    if (!is_array(global.mp_item_used))
        return;
    var used = global.mp_item_used;
    var gained = global.mp_item_gained;
    global.mp_item_used = -1;
    global.mp_item_gained = -1;
    var n = array_length(global.item);
    for (var u = 0; u < array_length(used); u++)
    {
        for (var i = 0; i < n; i++)
        {
            if (global.item[i] == used[u])
            {
                for (var k = i; k < (n - 1); k++)
                    global.item[k] = global.item[k + 1];
                global.item[n - 1] = 0;
                break;
            }
        }
    }
    for (var g = 0; g < array_length(gained); g++)
    {
        for (var j = 0; j < n; j++)
        {
            if (global.item[j] == 0)
            {
                global.item[j] = gained[g];
                break;
            }
        }
    }
}

// ---------------------------------------------------------------- the leader goes

function mp_leader_check()
{
    if (global.mp_gid == 0 || !global.mp_b_active || mp_b_lead())
        return;
    var l = global.mp_b_leader;
    var gone = !global.mp_pconn[l];
    // Left the fight (their game no longer reports being in one).
    if (!gone && (global.mp_pstate[l] & 1) == 0 && (current_time - global.mp_ppostime[l]) < 5000 && (current_time - global.mp_bwait_since) > 5000 && global.mp_bwait)
        gone = true;
    if (!gone)
        return;
    global.mp_b_mask &= ~(1 << l);
    for (var i = 0; i < 8; i++)
    {
        if (mp_in_mask(i) && global.mp_pconn[i] && global.mp_tdone_bid[i] == global.mp_bid)
        {
            global.mp_b_leader = i;
            mp_log("fight leader is now player " + string(i));
            return;
        }
    }
    // Nobody the arrays know of: me.
    global.mp_b_leader = global.mp_myid;
}

// ---------------------------------------------------------------- party wipe

// Only that fight's players go down. They see the Game Over screen and continue from the entrance
// of the room, with some HP. Nothing is reloaded, so the shared story and everyone else carry on.
function mp_wipe_mark()
{
    if (!mp_open_fight())
        return;
    global.mp_wipe = 1;
    global.mp_wipe_room = room;
    global.mp_wipe_x = global.mp_entry_room == room ? global.mp_entry_x : global.mp_my_x;
    global.mp_wipe_y = global.mp_entry_room == room ? global.mp_entry_y : global.mp_my_y;
}

// Prepended to scr_load. True: this is a continue after a wipe of my fight, nothing to load.
function mp_wipe_return()
{
    if (!variable_global_exists("mp_inited") || !global.mp_wipe)
        return false;
    global.mp_wipe = 0;
    global.mp_gameover = 0;
    mp_log("continuing after a wipe, back to the room's entrance");
    var c = global.mp_pchar[global.mp_myid];
    if (mp_hero_ok(c) && global.maxhp[c] > 0)
        global.hp[c] = max(global.hp[c], ceil(global.maxhp[c] / 2));
    for (var s = 0; s < 3; s++)
    {
        var sc = global.char[s];
        if (sc > 0 && global.hp[sc] <= 0)
            global.hp[sc] = ceil(global.maxhp[sc] / 2);
    }
    global.mp_scenes_killed = 0;
    global.mp_postbattle = 0;
    global.mp_postbattle_waits = 0;
    global.mp_warp_mus = -1;
    mp_warp(global.mp_wipe_room, global.mp_wipe_x, global.mp_wipe_y, 0);
    return true;
}

// Remembers where I came into a room.
function mp_entry_tick()
{
    if (global.mp_entry_room != room && instance_exists(obj_mainchara) && global.mp_room_frames > 3 && !global.mp_warp_pending)
    {
        global.mp_entry_room = room;
        global.mp_entry_x = obj_mainchara.x;
        global.mp_entry_y = obj_mainchara.y;
    }
}

// ---------------------------------------------------------------- walking up to a fight

// Every frame out of battle: is there a fight within reach?
function mp_join_tick()
{
    global.mp_join_target = -1;
    if ((current_time - global.mp_join_asked) < 3000)
        return;
    if (!global.mp_open || mp_in_battle_scene() || global.mp_enc_waiting || global.interact != 0 || global.mp_sstate != 0 || !instance_exists(obj_mainchara) || global.mp_ui_open)
        return;
    var best = 90;
    for (var i = 0; i < 8; i++)
    {
        if (i == global.mp_myid || !global.mp_pconn[i] || global.mp_proom[i] != room || (global.mp_pstate[i] & 1) == 0)
            continue;
        var d = point_distance(obj_mainchara.x, obj_mainchara.y, global.mp_px[i], global.mp_py[i]);
        if (d < best)
        {
            best = d;
            global.mp_join_target = i;
        }
    }
}

// At the start of a frame. True: the Z was for joining, the game doesn't get it.
function mp_join_input()
{
    if (global.mp_join_target < 0 || !global.mp_pconn[global.mp_join_target])
        return false;
    if (!global.input_pressed[4] && !mp_test_join_now())
        return false;
    mp_join_request(global.mp_join_target);
    global.mp_join_target = -1;
    return true;
}

function mp_join_request(target)
{
    mp_log("asking to join player " + string(target) + "'s fight");
    global.mp_join_asked = current_time;
    mp_notify("Joining " + global.mp_pname[target] + "'s fight...");
    mp_begin(52);
    mp_wu8(target);
    mp_send();
}

// A player asks to join through me: invite just them.
function mp_join_answer(from)
{
    if (!mp_battle_on() || from < 0 || from >= 8)
        return;
    global.mp_b_mask |= (1 << from);
    global.mp_pull_mask = 1 << from;
    mp_send_pull(1);
    global.mp_pull_mask = -1;
}

function mp_test_join_now()
{
    if (global.mp_test == "" || mp_test_arg("joinat") == "")
        return false;
    return global.mp_frame >= real(mp_test_arg("joinat"));
}

// ---------------------------------------------------------------- the host's setting

function mp_open_send()
{
    if (global.mp_role != 1)
        return;
    mp_begin(39);
    mp_wu8(global.mp_open);
    mp_send();
}
