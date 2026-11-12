#ifndef CDRACO_H
#define CDRACO_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct cdraco_mesh cdraco_mesh;

/// Decodes a Draco mesh. Returns NULL for anything malformed or that isn't a triangle mesh.
cdraco_mesh *cdraco_decode(const uint8_t *data, size_t length);
void cdraco_free(cdraco_mesh *m);
uint32_t cdraco_vertex_count(const cdraco_mesh *m);
uint32_t cdraco_face_count(const cdraco_mesh *m);
/// Writes three indices per face; `out` must hold face_count * 3 values.
void cdraco_indices(const cdraco_mesh *m, uint32_t *out);
/// Writes `components` floats per vertex for an attribute, by the unique ID glTF gives for it.
/// `out` must hold vertex_count * components values. Returns 1 on success.
int cdraco_attribute(const cdraco_mesh *m, uint32_t unique_id, int components, float *out);

#ifdef __cplusplus
}
#endif
#endif
