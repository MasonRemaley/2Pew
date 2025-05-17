struct MaterialInstancePacked {
    uint material_data_u16;
    uint data_u32;
};

struct MaterialInstance {
    uint material;
    uint data_u16;
    uint data_u32;
};

MaterialInstance materialUnpack(MaterialInstancePacked packed) {
    MaterialInstance instance;
    instance.material = packed.material_data_u16 & 0x0000FFFF;
    instance.data_u16 = packed.material_data_u16 >> 16;
    instance.data_u32 = packed.data_u32;
    return instance;
}
