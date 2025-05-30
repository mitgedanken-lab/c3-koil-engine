module client;
import common;
import common::msg;
import std::math;
import std::sort;
import std::io;
import std::collections::map;

const float NEAR_CLIPPING_PLANE = 0.1;
const float FAR_CLIPPING_PLANE = 10.0;
const float FOV = math::PI*0.5;
const float EPS = 1e-6;
const usz SPRITE_POOL_CAPACITY = 1000;
const usz PARTICLE_POOL_CAPACITY = 1000;
const float PARTICLE_LIFETIME = 1.0f;
const float PARTICLE_MAX_SPEED = 8;
const float PARTICLE_DAMP = 0.8;
const float PARTICLE_SCALE = 0.05;
const uint PING_COOLDOWN = 60;

const float ITEM_FREQ = 0.7;
const float ITEM_AMP = 0.07;

const int BOMB_PARTICLE_COUNT = 50;

const bool MINIMAP_SPRITES = true;
const float MINIMAP_SPRITE_SIZE = 0.2;
const float MINIMAP_SCALE = 0.07;

const uint SPRITE_ANGLES_COUNT = 8;

usz temp_mark = 0;
fn void reset_temp_mark() @export("reset_temp_mark") {
    allocator::temp().reset(temp_mark);
}

fn void* allocate_temporary_buffer(usz size) @extern("allocate_temporary_buffer") @wasm {
    return mem::tcalloc(size);
}

struct Color {
    char r;
    char g;
    char b;
    char a;
}

struct Image {
    usz width;
    usz height;
    Color *pixels;
}

struct Sprite {
    Image *image;
    // TODO: Use Vector3 instead
    // We can't do it right now due to some alignment restriction stuff
    Vector2 position;
    float z;
    float scale;
    IVector2 crop_position;
    IVector2 crop_size;

    float dist;  // Actual distance.
    float pdist; // Perpendicular distance.
    float t;     // Normalized horizontal position on the screen
}

struct SpritePool {
    Sprite[SPRITE_POOL_CAPACITY] items;
    int length;
    Sprite*[SPRITE_POOL_CAPACITY] visible_items;
    int visible_length;
}
SpritePool sprite_pool;

fn void reset_sprite_pool() {
    sprite_pool.length = 0;
    sprite_pool.visible_length = 0;
}

struct Particle {
    float lifetime;
    // TODO: Use Vector3 instead
    // We can't do it right now due to some alignment restriction stuff
    Vector2 position;
    float position_z;
    Vector2 velocity;
    float velocity_z;
}

struct ParticlePool {
    Particle[PARTICLE_POOL_CAPACITY] items;
}
extern ParticlePool particle_pool @extern("particle_pool");

struct Camera {
    Vector2 position;
    float direction;
    Vector2 fovLeft;
    Vector2 fovRight;
}

extern fn void camera_update(Camera *camera) @extern("camera_update");

struct Display {
    Image image;
    float *zbuffer;
}

extern Display display @extern("display");

fn void resize_display(usz width, usz height) @extern("resize_display") @wasm
{
    if (display.image.pixels) mem::free(display.image.pixels);
    if (display.zbuffer) mem::free(display.zbuffer);
    display.image.width = width;
    display.image.height = height;
    display.image.pixels = mem::calloc(Color.sizeof*width*height);
    display.zbuffer = mem::calloc(float.sizeof*width);
}

extern fn void render_floor_and_ceiling(Image *display) @extern("render_floor_and_ceiling");
extern fn void render_walls(Image *display, float *zbuffer, Image *wall) @extern("render_walls");
extern fn void cull_and_sort_sprites(SpritePool *sprite_pool) @extern("cull_and_sort_sprites");
extern fn void push_sprite(SpritePool *sprite_pool, Image *image, Vector3 position, float scale, IVector2 crop_position, IVector2 crop_size) @extern("push_sprite");
extern fn void render_sprites(Image *display, float *zbuffer, SpritePool *sprite_pool) @extern("render_sprites");
extern fn void emit_particle(Vector3 source, ParticlePool *particle_pool) @extern("emit_particle");
extern fn void update_particles(Image *image, SpritePool *sprite_pool, float deltaTime, ParticlePool *particle_pool) @extern("update_particles");
extern fn void kill_all_items(Item* items, usz items_count) @extern("kill_all_items");

fn bool apply_items_collected_batch_message(ItemsCollectedBatchMessage *message, Item* items, usz items_count) {
    usz count = (message.byte_length - ItemsCollectedBatchMessage.sizeof)/int.sizeof;

    for (usz i = 0; i < count; ++i) {
        int itemIndex = message.payload[i];

        if (!(0 <= itemIndex && itemIndex < items_count)) {
            io::printn(string::tformat("Received bogus-amogus ItemCollected message from server. Invalid index %d", itemIndex));
            return false;
        }

        Item *item = &items[itemIndex];

        if (item.alive) {
            item.alive = false;
            platform::play_sound(ITEM_PICKUP, me.position.x, me.position.y, item.position.x, item.position.y);
        }
    }

    return true;
}

fn bool apply_items_spawned_batch_message(ItemsSpawnedBatchMessage *message, Item* items, usz items_count) {
    usz count = (message.byte_length - ItemsCollectedBatchMessage.sizeof)/ItemSpawned.sizeof;
    for (usz i = 0; i < count; ++i) {
        int itemIndex = message.payload[i].itemIndex;
        if (!(0 <= itemIndex && itemIndex < items_count)) {
            io::printn(string::tformat("Received bogus-amogus ItemSpawned message from server. Invalid item index %d", itemIndex));
            return false;
        }
        Item *item = &items[itemIndex];
        item.alive = true;
        item.kind = message.payload[i].itemKind;
        item.position.x = message.payload[i].x;
        item.position.y = message.payload[i].y;
    }

    return true;
}

extern fn void render_items(SpritePool *sprite_pool, Item* items, usz items_count, float time, Image *key_image, Image *bomb_image) @extern("render_items");
extern fn void update_items(SpritePool *sprite_pool, float time, Item *items, usz items_count, Image *key_image, Image *bomb_image) @extern("update_items");
extern fn void explode_bomb(Vector3 bomb_position, Vector2 player_position, ParticlePool *particle_pool) @extern("explode_bomb");
extern fn void update_bombs_on_client_side(SpritePool *sprite_pool, ParticlePool *particle_pool, Image *bomb_image, float delta_time, Bombs *bombs) @extern("update_bombs_on_client_side");

fn bool apply_bombs_spawned_batch_message(BombsSpawnedBatchMessage *message, Bombs *bombs) {
    usz count = (message.byte_length - BombsSpawnedBatchMessage.sizeof)/BombSpawned.sizeof;
    for (usz i = 0; i < count; ++i) {
        int bombIndex = message.payload[i].bombIndex;
        if (!(0 <= bombIndex && bombIndex < bombs.len)) {
            io::printn(string::tformat("Received bogus-amogus BombSpawned message from server. Invalid bomb index %d", bombIndex));
            return false;
        }
        Bomb *bomb = &(*bombs)[bombIndex];
        bomb.lifetime   = message.payload[i].lifetime;
        bomb.position.x = message.payload[i].x;
        bomb.position.y = message.payload[i].y;
        bomb.position_z = message.payload[i].z;
        bomb.velocity.x = message.payload[i].dx;
        bomb.velocity.y = message.payload[i].dy;
        bomb.velocity_z = message.payload[i].dz;
    }

    return true;
}

fn bool apply_bombs_exploded_batch_message(BombsExplodedBatchMessage *message, Bombs *bombs, ParticlePool *particle_pool) {
    usz count = (message.byte_length - BombsExplodedBatchMessage.sizeof)/BombExploded.sizeof;
    for (usz i = 0; i < count; ++i) {
        int bombIndex = message.payload[i].bombIndex;
        if (!(0 <= bombIndex && bombIndex < bombs.len)) {
            io::printn(string::tformat("Received bogus-amogus BombExploded message from server. Invalid bomb index %d", bombIndex));
            return false;
        }
        Bomb *bomb = &(*bombs)[bombIndex];
        bomb.lifetime = 0.0;
        bomb.position.x = message.payload[i].x;
        bomb.position.y = message.payload[i].y;
        bomb.position_z = message.payload[i].z;
        explode_bomb({bomb.position.x, bomb.position.y, bomb.position_z}, me.position, particle_pool);
    }

    return true;
}

fn bool apply_hello_message_to_me(HelloPlayer hello_player, Item *items, usz items_count) {
    // TODO: maybe we should reset everything (bombs, etc) on hello message
    // So to let the server recreate the world properly
    kill_all_items(items, items_count);
    me.id         = hello_player.id;
    me.position.x = hello_player.x;
    me.position.y = hello_player.y;
    me.direction  = hello_player.direction;
    me.moving     = 0;
    me.hue        = hello_player.hue;
    return true;
}

fn void apply_players_joined_batch_message(PlayersJoinedBatchMessage *message) {
    usz count = (message.byte_length - PlayersJoinedBatchMessage.sizeof)/PlayerStruct.sizeof;
    for (usz i = 0; i < count; ++i) {
        PlayerStruct *player_struct = &message.payload[i];
        uint id = player_struct.id;
        if (try player = other_players.get_ref(id)) {
            player.position.x = player_struct.x;
            player.position.y = player_struct.y;
            player.direction = player_struct.direction;
            player.moving = player_struct.moving;
            player.hue = player_struct.hue;
        } else if (me.id == id) {
            // Recieved info about ourselves joining. It can actually happen.
            me.position.x = player_struct.x;
            me.position.y = player_struct.y;
            me.direction  = player_struct.direction;
            me.moving     = player_struct.moving;
            me.hue        = player_struct.hue;
        } else {
            other_players.set(id, {
                .id = id,
                .position = {player_struct.x, player_struct.y},
                .direction = player_struct.direction,
                .moving = player_struct.moving,
                .hue = player_struct.hue,
            });
        }
    }
}

fn void apply_players_left_batch_message(PlayersLeftBatchMessage *message) {
    usz count = message.count();
    for (usz i = 0; i < count; ++i) {
        other_players.remove(message.payload[i]);
    }
}

fn bool apply_players_moving_batch_message(PlayersMovingBatchMessage *message) {
    usz count = message.count();
    for (usz i = 0; i < count; ++i) {
        PlayerStruct *player_struct = &message.payload[i];
        uint id = player_struct.id;
        if (try player = other_players.get_ref(id)) {
            player.moving = player_struct.moving;
            player.position.x = player_struct.x;
            player.position.y = player_struct.y;
            player.direction = player_struct.direction;
        } else if (me.id == id) {
            me.moving = player_struct.moving;
            me.position.x = player_struct.x;
            me.position.y = player_struct.y;
            me.direction = player_struct.direction;
        } else {
            io::printn(string::tformat("Received bogus-amogus message from server. We don't know anything about player with id %d", id));
            return false;
        }
    }
    return true;
}

extern fn uint sprite_angle_index(Vector2 camera_position, Player entity) @extern("sprite_angle_index");

fn void update_all_players(float delta_time) {
    other_players.@each_entry(; OtherPlayersEntry *entry) {
        common::update_player(&entry.value, delta_time);
    };
    common::update_player(&me, delta_time);
}

fn void render_other_players(SpritePool *sprite_pool, Image *player_image) {
    other_players.@each_entry(; OtherPlayersEntry *entry) {
        uint index = sprite_angle_index(me.position, entry.value);
        push_sprite(sprite_pool, player_image, {entry.value.position.x, entry.value.position.y, 1}, 1, {55*index, 0}, {55, 55});
    };
}


extern fn void* pack_ptr_by_offset(usz offset) @extern("pack_ptr_by_offset");
extern fn Asset *asset_by_filename(ZString filename) @extern("asset_by_filename");

fn void render_game(float delta_time, float time) @extern("render_game") @wasm {
    Asset *asset = null;

    asset = asset_by_filename("assets/images/custom/key.png");
    assert(asset);
    Image key_image = {asset.width, asset.height, (Color*)pack_ptr_by_offset(asset.offset)};

    asset = asset_by_filename("assets/images/custom/bomb.png");
    assert(asset);
    Image bomb_image = {asset.width, asset.height, (Color*)pack_ptr_by_offset(asset.offset)};

    asset = asset_by_filename("assets/images/custom/particle.png");
    assert(asset);
    Image particle_image = {asset.width, asset.height, (Color*)pack_ptr_by_offset(asset.offset)};

    asset = asset_by_filename("assets/images/custom/wall.png");
    assert(asset);
    Image wall_image = {asset.width, asset.height, (Color*)pack_ptr_by_offset(asset.offset)};

    asset = asset_by_filename("assets/images/custom/player.png");
    assert(asset);
    Image player_image = {asset.width, asset.height, (Color*)pack_ptr_by_offset(asset.offset)};

    update_all_players(delta_time);
    update_items(&sprite_pool, time, common::items_ptr(), common::items_len(), &key_image, &bomb_image);
    update_bombs_on_client_side(&sprite_pool, &particle_pool, &bomb_image, delta_time, &common::bombs);
    update_particles(&particle_image, &sprite_pool, delta_time, &particle_pool);

    render_other_players(&sprite_pool, &player_image);

    render_floor_and_ceiling(&display.image);
    render_walls(&display.image, display.zbuffer, &wall_image);
    cull_and_sort_sprites(&sprite_pool);
    render_sprites(&display.image, display.zbuffer, &sprite_pool);

    ping_server_if_needed();
    reset_sprite_pool();
    reset_temp_mark();
}

uint ping_cooldown = PING_COOLDOWN;
fn void ping_server_if_needed() {
    if (!platform::is_offline_mode()) {
        ping_cooldown -= 1;
        if (ping_cooldown == 0) {
            platform::send_message(&&PingMessage {
                .byte_length = PingMessage.sizeof,
                .kind = PING,
                .payload = platform::now_msecs(),
            });
            ping_cooldown = PING_COOLDOWN;
        }
    }
}

uint ping = 0;
fn void process_pong_message(PongMessage *message) {
    ping = platform::now_msecs() - message.payload;
}

fn uint ping_msecs() @extern("ping_msecs") @wasm {
    return ping;
}

fn bool process_message(Message *message) @extern("process_message") @wasm {
    if (common::verify_hello_message(message)) {
        apply_hello_message_to_me(((HelloMessage*)message).payload, common::items_ptr(), common::items_len());
        return true;
    }
    if (common::verify_players_joined_batch_message(message)) {
        apply_players_joined_batch_message((PlayersJoinedBatchMessage*)message);
        return true;
    }
    if (common::verify_players_left_batch_message(message)) {
        apply_players_left_batch_message((PlayersLeftBatchMessage*)message);
        return true;
    }
    if (common::verify_players_moving_batch_message(message)) {
        if (!apply_players_moving_batch_message((PlayersMovingBatchMessage*)message)) return false;
        return true;
    }
    if (common::verify_pong_message(message)) {
        process_pong_message((PongMessage*)message);
        return true;
    }
    if (common::verify_items_collected_batch_message(message)) {
        if (!apply_items_collected_batch_message((ItemsCollectedBatchMessage*)message, common::items_ptr(), common::items_len())) return false;
        return true;
    }
    if (common::verify_items_spawned_batch_message(message)) {
        if (!apply_items_spawned_batch_message((ItemsSpawnedBatchMessage*)message, common::items_ptr(), common::items_len())) return false;
        return true;
    }
    if (common::verify_bombs_spawned_batch_message(message)) {
        if (!apply_bombs_spawned_batch_message((BombsSpawnedBatchMessage*)message, &common::bombs)) return false;
        return true;
    }
    if (common::verify_bombs_exploded_batch_message(message)) {
        if (!apply_bombs_exploded_batch_message((BombsExplodedBatchMessage*)message, &common::bombs, &particle_pool)) return false;
        return true;
    }
    // TODO: print the bytes of the bogus amogus message
    io::printn(string::tformat("Received bogus-amogus message from server. %s", message));
    return false;
}

extern Player me @extern("me");
def OtherPlayersEntry = Entry(<uint, Player>);
HashMap(<uint, Player>) other_players;

fn uint players_count() @extern("players_count") @wasm {
    return other_players.len() + 1; // +1 including `me`
}

fn void unregister_all_other_players() @extern("unregister_all_other_players") @wasm {
    other_players.clear();
}

fn void entry() @init(2048) @private {
    // NOTE: ideally we need to override os::native_fputc_fn as well
    // because io::printn uses it to print newline at the end of the
    // message. But since js_write() in server.mts is implemented as a
    // single console.log(), that newline is added implicitly anyway.
    os::native_fwrite_fn = fn usz!(void* f, char[] buffer) {
        client::platform::write(&buffer[0], buffer.len);
        return buffer.len;
    };
    temp_mark = allocator::temp().used;
}

module client::platform;

// WARNING! Must be synchronized with AssetSound in client.mts
enum AssetSound {
    BOMB_BLAST,
    BOMB_RICOCHET,
    ITEM_PICKUP,
}

// TODO: Use std::math::random instead (when you finally figure out how to use it)
extern fn float random() @extern("platform_random");
extern fn void play_sound(AssetSound sound, float player_position_x, float player_position_y, float object_position_x, float object_position_y) @extern("platform_play_sound");
extern fn bool is_offline_mode() @extern("platform_is_offline_mode");
extern fn bool send_message(void *message) @extern("platform_send_message");
extern fn uint now_msecs() @extern("platform_now_msecs");
extern fn void write(void *buffer, usz buffer_sz) @extern("platform_write");
extern fn float atan2f(float y, float x) @extern("platform_atan2f");
