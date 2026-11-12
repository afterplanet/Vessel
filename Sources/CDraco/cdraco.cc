#include "include/cdraco.h"
#include <memory>
#include "draco/compression/decode.h"
#include "draco/mesh/mesh.h"

struct cdraco_mesh { std::unique_ptr<draco::Mesh> mesh; };

extern "C" cdraco_mesh *cdraco_decode(const uint8_t *data, size_t length) {
    if (!data || length == 0) return nullptr;
    draco::DecoderBuffer buffer;
    buffer.Init(reinterpret_cast<const char *>(data), length);
    auto type = draco::Decoder::GetEncodedGeometryType(&buffer);
    if (!type.ok() || type.value() != draco::TRIANGULAR_MESH) return nullptr;
    draco::Decoder decoder;
    auto result = decoder.DecodeMeshFromBuffer(&buffer);
    if (!result.ok() || !result.value()) return nullptr;
    auto *out = new cdraco_mesh();
    out->mesh = std::move(result).value();
    return out;
}

extern "C" void cdraco_free(cdraco_mesh *m) { delete m; }
extern "C" uint32_t cdraco_vertex_count(const cdraco_mesh *m) { return m->mesh->num_points(); }
extern "C" uint32_t cdraco_face_count(const cdraco_mesh *m) { return m->mesh->num_faces(); }

extern "C" void cdraco_indices(const cdraco_mesh *m, uint32_t *out) {
    const uint32_t n = m->mesh->num_faces();
    for (draco::FaceIndex f(0); f < n; ++f) {
        const auto &face = m->mesh->face(f);
        for (int c = 0; c < 3; ++c) *out++ = face[c].value();
    }
}

extern "C" int cdraco_attribute(const cdraco_mesh *m, uint32_t unique_id, int components, float *out) {
    const draco::PointAttribute *a = m->mesh->GetAttributeByUniqueId(unique_id);
    if (!a || components < 1 || components > 4 || a->num_components() < components) return 0;
    float value[8];
    const uint32_t n = m->mesh->num_points();
    for (draco::PointIndex p(0); p < n; ++p) {
        if (!a->ConvertValue<float>(a->mapped_index(p), components, value)) return 0;
        for (int c = 0; c < components; ++c) *out++ = value[c];
    }
    return 1;
}
