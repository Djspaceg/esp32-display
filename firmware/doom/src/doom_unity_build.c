// Unity build for the Doom engine on supported ESP32 targets.
// Compiles all engine + platform C source as one translation unit,
// eliminating linker archive issues with Arduino's library system.
// This file is the ONLY .c that needs to be compiled for the engine.
//
// Why: Arduino's library linker uses archive mode which strips "unused"
// symbols from .a files. Since the engine's internal symbols reference
// each other circularly (I_Error in stubs, DG_DrawFrame in platform,
// W_OpenFile in WAD access), archive linking fails. Unity build solves
// this by putting everything in one object file.

#include <esp_heap_caps.h>
#include <stdbool.h>
#include <string.h>

// Platform stubs and bridge (order matters: stubs before engine)
#include "platform/doom_esp32_stubs.c.inc"
#include "platform/doomgeneric_esp32.c.inc"
#include "platform/w_file_esp32.c.inc"

// Network stub
#include "net_sdl.c.inc"

// Engine source (alphabetical)
#include "am_map.c.inc"
#include "d_event.c.inc"
#include "d_items.c.inc"
#include "d_iwad.c.inc"
#include "d_loop.c.inc"
#include "d_main.c.inc"
#include "d_mode.c.inc"
#include "d_net.c.inc"
#include "doomdef.c.inc"
#include "doomgeneric.c.inc"
#include "doomstat.c.inc"
#include "dstrings.c.inc"
#include "dummy.c.inc"
#include "f_finale.c.inc"
#include "f_wipe.c.inc"
#include "g_game.c.inc"
#include "gusconf.c.inc"
#include "hu_lib.c.inc"
#include "hu_stuff.c.inc"
#include "i_cdmus.c.inc"
#include "i_endoom.c.inc"
#include "i_input.c.inc"
#include "i_joystick.c.inc"
#include "i_scale.c.inc"
#include "i_sound.c.inc"
#include "i_system.c.inc"
#include "i_timer.c.inc"
#include "i_video.c.inc"
#include "info.c.inc"
#include "m_argv.c.inc"
#include "m_bbox.c.inc"
#include "m_cheat.c.inc"
#include "m_config.c.inc"
#include "m_controls.c.inc"
#include "m_fixed.c.inc"
#include "m_menu.c.inc"
#include "m_misc.c.inc"
#include "m_random.c.inc"
#include "memio.c.inc"
#include "mus2mid.c.inc"
#include "p_ceilng.c.inc"
#include "p_doors.c.inc"
#include "p_enemy.c.inc"
#include "p_floor.c.inc"
#include "p_inter.c.inc"
#include "p_lights.c.inc"
#include "p_map.c.inc"
#include "p_maputl.c.inc"
#include "p_mobj.c.inc"
#include "p_plats.c.inc"
#include "p_pspr.c.inc"
#include "p_saveg.c.inc"
#include "p_setup.c.inc"
#include "p_sight.c.inc"
#include "p_spec.c.inc"
#include "p_switch.c.inc"
#include "p_telept.c.inc"
#include "p_tick.c.inc"
#include "p_user.c.inc"
#include "r_bsp.c.inc"
#include "r_data.c.inc"
#include "r_draw.c.inc"
#include "r_main.c.inc"
#include "r_plane.c.inc"
#include "r_segs.c.inc"
#include "r_sky.c.inc"
#include "r_things.c.inc"
#include "s_sound.c.inc"
#include "sha1.c.inc"
#include "sounds.c.inc"
#include "st_lib.c.inc"
#include "st_stuff.c.inc"
#include "statdump.c.inc"
#include "tables.c.inc"
#include "v_video.c.inc"
#include "w_checksum.c.inc"
#include "w_main.c.inc"
#include "w_wad.c.inc"
#include "wi_stuff.c.inc"
#include "z_zone.c.inc"

// Arduino's precompiled IDF permits PSRAM heap allocation but not external
// BSS placement. Allocate only the largest Doom renderer work arrays here;
// display_stream's DMA staging and UDP codec scratch remain internal.
bool doom_prepare_static_buffers(void) {
    const uint32_t caps = MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT;
    if (visplanes == NULL) {
        visplanes = (visplane_t*)heap_caps_calloc(
            MAXVISPLANES, sizeof(*visplanes), caps);
    }
    if (openings == NULL) {
        openings = (short*)heap_caps_calloc(MAXOPENINGS, sizeof(*openings), caps);
    }
    if (viewangletox == NULL) {
        viewangletox = (int*)heap_caps_calloc(
            FINEANGLES / 2, sizeof(*viewangletox), caps);
    }
    if (drawsegs == NULL) {
        drawsegs = (drawseg_t*)heap_caps_calloc(
            MAXDRAWSEGS, sizeof(*drawsegs), caps);
    }
    if (vissprites == NULL) {
        vissprites = (vissprite_t*)heap_caps_calloc(
            MAXVISSPRITES, sizeof(*vissprites), caps);
    }
    if (captured_stats == NULL) {
        captured_stats = (wbstartstruct_t*)heap_caps_calloc(
            MAX_CAPTURES, sizeof(*captured_stats), caps);
    }
    if (states == NULL) {
        states = (state_t*)heap_caps_malloc(sizeof(doom_initial_states), caps);
        if (states != NULL) {
            memcpy(states, doom_initial_states, sizeof(doom_initial_states));
        }
    }
    if (mobjinfo == NULL) {
        mobjinfo = (mobjinfo_t*)heap_caps_malloc(
            sizeof(doom_initial_mobjinfo), caps);
        if (mobjinfo != NULL) {
            memcpy(mobjinfo, doom_initial_mobjinfo,
                   sizeof(doom_initial_mobjinfo));
        }
    }
    // Doom-only globals relocated from internal DRAM (.bss/COMMON) to PSRAM.
    // calloc zero-inits to match BSS semantics; each runs before first read.
    if (ticdata == NULL)
        ticdata = (ticcmd_set_t*)heap_caps_calloc(BACKUPTICS, sizeof(*ticdata), caps);
    if (columnofs == NULL)
        columnofs = (int*)heap_caps_calloc(MAXWIDTH, sizeof(*columnofs), caps);
    if (ylookup == NULL)
        ylookup = (byte**)heap_caps_calloc(MAXHEIGHT, sizeof(*ylookup), caps);
    if (translations == NULL)
        translations = (byte(*)[256])heap_caps_calloc(3, sizeof(*translations), caps);
    if (intercepts == NULL)
        intercepts = (intercept_t*)heap_caps_calloc(MAXINTERCEPTS, sizeof(*intercepts), caps);
    if (xtoviewangle == NULL)
        xtoviewangle = (angle_t*)heap_caps_calloc(SCREENWIDTH + 1, sizeof(*xtoviewangle), caps);
    if (itemrespawnque == NULL)
        itemrespawnque = (mapthing_t*)heap_caps_calloc(ITEMQUESIZE, sizeof(*itemrespawnque), caps);
    if (itemrespawntime == NULL)
        itemrespawntime = (int*)heap_caps_calloc(ITEMQUESIZE, sizeof(*itemrespawntime), caps);
    if (distscale == NULL)
        distscale = (fixed_t*)heap_caps_calloc(SCREENWIDTH, sizeof(*distscale), caps);
    if (players == NULL)
        players = (player_t*)heap_caps_calloc(MAXPLAYERS, sizeof(*players), caps);
    if (consistancy == NULL)
        consistancy = (byte(*)[BACKUPTICS])heap_caps_calloc(MAXPLAYERS, sizeof(*consistancy), caps);
    if (events == NULL)
        events = (event_t*)heap_caps_calloc(MAXEVENTS, sizeof(*events), caps);
    if (gamekeydown == NULL)
        gamekeydown = (boolean*)heap_caps_calloc(NUMKEYS, sizeof(*gamekeydown), caps);
    if (colors == NULL)
        colors = (struct color*)heap_caps_calloc(256, sizeof(*colors), caps);
    if (wadfile == NULL)
        wadfile = (char*)heap_caps_calloc(1024, sizeof(*wadfile), caps);
    if (mapdir == NULL)
        mapdir = (char*)heap_caps_calloc(1024, sizeof(*mapdir), caps);
    if (sprtemp == NULL)
        sprtemp = (spriteframe_t*)heap_caps_calloc(29, sizeof(*sprtemp), caps);
    if (yslope == NULL)
        yslope = (fixed_t*)heap_caps_calloc(SCREENHEIGHT, sizeof(*yslope), caps);
    if (spanstart == NULL)
        spanstart = (int*)heap_caps_calloc(SCREENHEIGHT, sizeof(*spanstart), caps);
    if (spanstop == NULL)
        spanstop = (int*)heap_caps_calloc(SCREENHEIGHT, sizeof(*spanstop), caps);
    if (cachedheight == NULL)
        cachedheight = (fixed_t*)heap_caps_calloc(SCREENHEIGHT, sizeof(*cachedheight), caps);
    if (cacheddistance == NULL)
        cacheddistance = (fixed_t*)heap_caps_calloc(SCREENHEIGHT, sizeof(*cacheddistance), caps);
    if (cachedxstep == NULL)
        cachedxstep = (fixed_t*)heap_caps_calloc(SCREENHEIGHT, sizeof(*cachedxstep), caps);
    if (cachedystep == NULL)
        cachedystep = (fixed_t*)heap_caps_calloc(SCREENHEIGHT, sizeof(*cachedystep), caps);
    if (floorclip == NULL)
        floorclip = (short*)heap_caps_calloc(SCREENWIDTH, sizeof(*floorclip), caps);
    if (ceilingclip == NULL)
        ceilingclip = (short*)heap_caps_calloc(SCREENWIDTH, sizeof(*ceilingclip), caps);
    if (negonearray == NULL)
        negonearray = (short*)heap_caps_calloc(SCREENWIDTH, sizeof(*negonearray), caps);
    if (screenheightarray == NULL)
        screenheightarray = (short*)heap_caps_calloc(SCREENWIDTH, sizeof(*screenheightarray), caps);
    if (clipbot == NULL)
        clipbot = (short*)heap_caps_calloc(SCREENWIDTH, sizeof(*clipbot), caps);
    if (cliptop == NULL)
        cliptop = (short*)heap_caps_calloc(SCREENWIDTH, sizeof(*cliptop), caps);
    if (anims == NULL)
        anims = (anim_t*)heap_caps_calloc(MAXANIMS, sizeof(*anims), caps);
    if (linespeciallist == NULL)
        linespeciallist = (line_t**)heap_caps_calloc(MAXLINEANIMS, sizeof(*linespeciallist), caps);
    if (switchlist == NULL)
        switchlist = (int*)heap_caps_calloc(MAXSWITCHES * 2, sizeof(*switchlist), caps);
    if (solidsegs == NULL)
        solidsegs = (cliprange_t*)heap_caps_calloc(MAXSEGS, sizeof(*solidsegs), caps);
    if (iwad_dirs == NULL)
        iwad_dirs = (char**)heap_caps_calloc(MAX_IWAD_DIRS, sizeof(*iwad_dirs), caps);
    if (zlight == NULL)
        zlight = (lighttable_t*(*)[MAXLIGHTZ])heap_caps_calloc(LIGHTLEVELS, sizeof(*zlight), caps);
    if (scalelight == NULL)
        scalelight = (lighttable_t*(*)[MAXLIGHTSCALE])heap_caps_calloc(LIGHTLEVELS, sizeof(*scalelight), caps);
    if (scalelightfixed == NULL)
        scalelightfixed = (lighttable_t**)heap_caps_calloc(MAXLIGHTSCALE, sizeof(*scalelightfixed), caps);
    if (buttonlist == NULL)
        buttonlist = (button_t*)heap_caps_calloc(MAXBUTTONS, sizeof(*buttonlist), caps);
    if (activeplats == NULL)
        activeplats = (plat_t**)heap_caps_calloc(MAXPLATS, sizeof(*activeplats), caps);
    if (bodyque == NULL)
        bodyque = (mobj_t**)heap_caps_calloc(BODYQUESIZE, sizeof(*bodyque), caps);
    if (braintargets == NULL)
        braintargets = (mobj_t**)heap_caps_calloc(32, sizeof(*braintargets), caps);
    if (hu_font == NULL)
        hu_font = (patch_t**)heap_caps_calloc(HU_FONTSIZE, sizeof(*hu_font), caps);
    if (activeceilings == NULL)
        activeceilings = (ceiling_t**)heap_caps_calloc(MAXCEILINGS, sizeof(*activeceilings), caps);
    if (w_inputbuffer == NULL)
        w_inputbuffer = (hu_itext_t*)heap_caps_calloc(MAXPLAYERS, sizeof(*w_inputbuffer), caps);
    // S_music: .lumpnum/.data/.handle are written at runtime; allocate a
    // mutable PSRAM copy of the const template (matches states/mobjinfo).
    if (S_music == NULL) {
        S_music = (musicinfo_t*)heap_caps_malloc(sizeof(doom_initial_S_music), caps);
        if (S_music != NULL) {
            memcpy(S_music, doom_initial_S_music, sizeof(doom_initial_S_music));
        }
    }

    return visplanes != NULL && openings != NULL && viewangletox != NULL &&
           drawsegs != NULL && vissprites != NULL && captured_stats != NULL &&
           states != NULL && mobjinfo != NULL &&
           ticdata != NULL && columnofs != NULL && ylookup != NULL &&
           translations != NULL && intercepts != NULL && xtoviewangle != NULL &&
           itemrespawnque != NULL && itemrespawntime != NULL && distscale != NULL &&
           players != NULL && consistancy != NULL && events != NULL &&
           gamekeydown != NULL && colors != NULL && wadfile != NULL &&
           mapdir != NULL && sprtemp != NULL && yslope != NULL &&
           spanstart != NULL && spanstop != NULL && cachedheight != NULL &&
           cacheddistance != NULL && cachedxstep != NULL && cachedystep != NULL &&
           floorclip != NULL && ceilingclip != NULL && negonearray != NULL &&
           screenheightarray != NULL && clipbot != NULL && cliptop != NULL &&
           anims != NULL && linespeciallist != NULL && switchlist != NULL &&
           solidsegs != NULL && iwad_dirs != NULL && zlight != NULL &&
           scalelight != NULL && scalelightfixed != NULL && buttonlist != NULL &&
           activeplats != NULL && bodyque != NULL && braintargets != NULL &&
           S_music != NULL && hu_font != NULL && activeceilings != NULL &&
           w_inputbuffer != NULL;
}
