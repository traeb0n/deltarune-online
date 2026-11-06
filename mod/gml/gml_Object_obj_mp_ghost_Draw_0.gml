if (pid < 0 || !sprite_exists(sprite_index))
    exit;
draw_sprite_ext(sprite_index, image_index, x, y, image_xscale, image_yscale, 0, c_white, 1);
// A follower: just the figure, no name tag.
if (fol >= 0)
    exit;
// In a fight: a slow white pulse, so it reads as "busy" rather than a figure standing around.
var fighting = mp_ghost_fighting(pid);
if (fighting)
{
    gpu_set_fog(true, c_white, 0, 1);
    draw_sprite_ext(sprite_index, image_index, x, y, image_xscale, image_yscale, 0, c_white, 0.25 + (0.2 * sin(current_time / 250)));
    gpu_set_fog(false, c_white, 0, 1);
}
// Name tag above the sprite's centre (sprite origins differ: walking sprites have it at the top
// left, the Chapter 5 platformer's sprites don't).
var tcx = x + (((sprite_get_width(sprite_index) / 2) - sprite_get_xoffset(sprite_index)) * image_xscale);
var tty = y - (sprite_get_yoffset(sprite_index) * image_yscale);
mp_draw_nametag(pid, tcx, tty - 4);
if (fighting && global.mp_join_target == pid)
    mp_draw_join_prompt(tcx, tty - 22);
