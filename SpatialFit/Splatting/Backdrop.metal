//
//  Backdrop.metal
//  SpatialFit
//
//  Den uppmätta ytan bakom splatten, och hopfogningen av de två.
//
//  Splatten är sann där någon fotograferat och ingenting alls där ingen gjorde
//  det — och "ingenting" är genomskinligt, så tittar man mot ett sådant hål ser
//  man rakt igenom rummet. Meshen har inte det problemet: LiDAR mätte upp den
//  hela vägen runt, och den ligger sju millimeter från splattens egen yta. Läggs
//  den under blir hålen solida i stället för tomma.
//
//  Ordningen är därför: mesh in i bilden, splatten i en egen ruta, och sedan
//  splatten ovanpå med sin egen genomskinlighet. Där splatten är tät syns bara
//  den; där den tunnas ut träder meshen fram av sig själv.
//

#include <metal_stdlib>
using namespace metal;

struct BackdropUniforms {
    float4x4 viewProjection;
    /// Var betraktaren står. Ljuset sitter i kameran, så att ytan alltid har
    /// form — ett fast ljus lämnar halva rummet i svart.
    float3 eye;
    /// Grundfärgen när ingen bakad atlas finns.
    float3 tint;
};

struct MeshVertex {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float2 coordinate;
};

vertex MeshVertex backdropVertex(uint id [[vertex_id]],
                                 const device float3 *positions [[buffer(0)]],
                                 const device float3 *normals [[buffer(1)]],
                                 const device float2 *coordinates [[buffer(2)]],
                                 constant BackdropUniforms &uniforms [[buffer(3)]])
{
    MeshVertex out;
    float3 world = positions[id];
    out.position = uniforms.viewProjection * float4(world, 1.0);
    out.world = world;
    out.normal = normals[id];
    out.coordinate = coordinates[id];
    return out;
}

/// Hur mycket ytan mörknar när den vetter bort. Svag med flit: det här är en
/// bakgrund som ska fylla hål, inte ett föremål som ska framhävas.
static inline float shade(float3 normal, float3 world, float3 eye)
{
    float3 toEye = normalize(eye - world);
    // Meshens normaler kan peka in i rummet eller ut ur det. Rummet ses inifrån,
    // så beloppet är det som säger hur rakt på ytan träffas.
    return 0.55 + 0.45 * abs(dot(normalize(normal), toEye));
}

/// Med bakad atlas. Färgen lämnas som den är — ljuset ligger redan i den, och
/// att lysa på den en gång till gör bakgrunden ljusare än splatten framför.
fragment float4 backdropTexturedFragment(MeshVertex in [[stage_in]],
                                         constant BackdropUniforms &uniforms [[buffer(3)]],
                                         texture2d<float> atlas [[texture(0)]])
{
    constexpr sampler linear(mag_filter::linear, min_filter::linear,
                             mip_filter::linear, address::clamp_to_edge);
    return float4(atlas.sample(linear, in.coordinate).rgb, 1.0);
}

/// Utan atlas: en matt yta i rummets egen färgton, skuggad så att formen syns.
fragment float4 backdropPlainFragment(MeshVertex in [[stage_in]],
                                      constant BackdropUniforms &uniforms [[buffer(3)]])
{
    return float4(uniforms.tint * shade(in.normal, in.world, uniforms.eye), 1.0);
}

// MARK: - Hopfogningen

struct CompositeVertex {
    float4 position [[position]];
    float2 coordinate;
};

/// En enda triangel som täcker hela rutan. Billigare än två, och slipper
/// sömmen på diagonalen.
vertex CompositeVertex compositeVertex(uint id [[vertex_id]])
{
    float2 corner = float2((id << 1) & 2, id & 2);
    CompositeVertex out;
    out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    out.coordinate = float2(corner.x, 1.0 - corner.y);
    return out;
}

/// Vid hur lite egen täckning splatten får stå ensam. Under tröskeln tonas
/// meshen in i proportion, över den är den helt borta.
///
/// Varför en tröskel och inte rakt `1 - alfa`: rummet är fullt av gaussare med
/// nästan noll alfa, och var och en av dem släpper igenom nästan hela
/// bakgrunden. Staplade läcker meshens ljushet upp genom diset och lägger sig
/// som utblåsta högdagrar på ytor splatten redan beskriver. Med tröskeln
/// räcker det att några få dis-lager överlappar för att bakgrunden ska tystna.
constant float COVERAGE = 0.35;

/// Lägger splattens ruta över meshen. Blandningen görs här i stället för i
/// rörledningen, för bara här går det att se hur mycket splatten själv täcker.
///
/// `mesh` är bildens nuvarande innehåll — ytan som redan ritats. Att läsa den
/// är tillåtet därför att passagen laddar färgbufferten (`loadAction = .load`)
/// i stället för att rensa den.
///
/// Splattens färg är redan multiplicerad med sin alfa, så den läggs på rakt.
/// Meshen viktas ned mot noll i stället för mot `1 - alfa`: bakgrunden ska
/// fylla HÅL, inte lysa igenom det splatten redan målat.
fragment float4 compositeFragment(CompositeVertex in [[stage_in]],
                                  float4 mesh [[color(0)]],
                                  texture2d<float> splats [[texture(0)]])
{
    constexpr sampler nearest(mag_filter::nearest, min_filter::nearest,
                              address::clamp_to_edge);
    float4 splat = splats.sample(nearest, in.coordinate);
    float hole = saturate(1.0 - splat.a / COVERAGE);
    return float4(splat.rgb + mesh.rgb * hole, 1.0);
}
