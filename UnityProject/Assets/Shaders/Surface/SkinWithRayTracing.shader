Shader "Custom/SkinWithRayTracing"
{
    Properties
    {
        [MainTexture] _BaseMap("Albedo", 2D) = "white" {}
        [MainColor] _BaseColor("Color", Color) = (1,1,1,1)

        _Smoothness("Smoothness", Range(0.0, 1.0)) = 0.5

        _Metallic("Metallic", Range(0.0, 1.0)) = 0.0
        _MetallicGlossMap("Metallic", 2D) = "white" {}

        _BumpScale("Scale", Float) = 1.0
        _BumpMap("Normal Map", 2D) = "bump" {}

        // Micro normal (skin pore detail)
        [Normal] _MicroNormalMap("Micro Normal Map", 2D) = "bump" {}
        _MicroNormalStrength("Micro Normal Strength", Range(0.0, 2.0)) = 1.0
        _MicroNormalTiling("Micro Normal Tiling", Float) = 4.0
    }

    SubShader
    {
        Tags
        {
            "RenderType" = "Opaque"
            "RenderPipeline" = "UniversalPipeline"
            "UniversalMaterialType" = "Lit"
            "IgnoreProjector" = "True"
        }
        LOD 300

        UsePass "Universal Render Pipeline/Lit/ForwardLit"
        UsePass "Universal Render Pipeline/Lit/ShadowCaster"
        UsePass "Universal Render Pipeline/Lit/GBuffer"
        UsePass "Universal Render Pipeline/Lit/DepthOnly"
        UsePass "Universal Render Pipeline/Lit/DepthNormals"
        UsePass "Universal Render Pipeline/Lit/Meta"
        UsePass "Universal Render Pipeline/Lit/Universal2D"
        UsePass "Universal Render Pipeline/Lit/MotionVectors"
        UsePass "Universal Render Pipeline/Lit/XRMotionVectors"
    }

    SubShader
    {
        Pass
        {
            Name "Test2"

            Tags
            {
                "LightMode" = "RayTracing"
            }
            HLSLPROGRAM
            #include "UnityRaytracingMeshUtils.cginc"
            #include "Assets/Shaders/Include/ml.hlsli"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
 
                float4 _BaseMap_ST;
                float4 _BaseMap_TexelSize;
                float  _Smoothness;
                float  _Metallic;
                float  _BumpScale;
                // Micro normal
                float  _MicroNormalStrength;
                float  _MicroNormalTiling; 

                float4 _BaseColor;

            TEXTURE2D(_BaseMap);
            SAMPLER(sampler_BaseMap);
            TEXTURE2D(_BumpMap);
            SAMPLER(sampler_BumpMap);
            TEXTURE2D(_MetallicGlossMap);
            SAMPLER(sampler_MetallicGlossMap);
            TEXTURE2D(_MicroNormalMap);
            SAMPLER(sampler_MicroNormalMap);

            #include "Assets/Shaders/Include/Shared.hlsl"
            #include "Assets/Shaders/Include/Payload.hlsl"

            #pragma shader_feature_local_raytracing _EMISSION
            #pragma shader_feature_local_raytracing _NORMALMAP
            #pragma shader_feature_local_raytracing _METALLICSPECGLOSSMAP

            #pragma multi_compile_local RAY_TRACING_PROCEDURAL_GEOMETRY

            #pragma raytracing test
            #pragma enable_d3d11_debug_symbols
            #pragma use_dxc
            #pragma enable_ray_tracing_shader_debug_symbols
            #pragma require Native16Bit
            #pragma require int64

            struct AttributeData
            {
                float2 barycentrics;
            };

            struct Vertex
            {
                float3 position;
                float3 normal;
                float4 tangent;
                float2 uv;
            };

            float LengthSquared(float3 v)
            {
                return dot(v, v);
            }

            Vertex FetchVertex(uint vertexIndex)
            {
                Vertex v;
                v.position = UnityRayTracingFetchVertexAttribute3(vertexIndex, kVertexAttributePosition);
                v.normal   = UnityRayTracingFetchVertexAttribute3(vertexIndex, kVertexAttributeNormal);
                v.tangent  = UnityRayTracingFetchVertexAttribute4(vertexIndex, kVertexAttributeTangent);
                v.uv       = UnityRayTracingFetchVertexAttribute2(vertexIndex, kVertexAttributeTexCoord0);
                return v;
            }

            Vertex InterpolateVertices(Vertex v0, Vertex v1, Vertex v2, float3 barycentrics)
            {
                Vertex v;
                #define INTERPOLATE_ATTRIBUTE(attr) v.attr = v0.attr * barycentrics.x + v1.attr * barycentrics.y + v2.attr * barycentrics.z
                INTERPOLATE_ATTRIBUTE(position);
                INTERPOLATE_ATTRIBUTE(normal);
                INTERPOLATE_ATTRIBUTE(tangent);
                INTERPOLATE_ATTRIBUTE(uv);
                return v;
            }

            // Blend two tangent-space normals (reoriented normal mapping)
            float3 BlendNormals(float3 baseNormal, float3 detailNormal)
            {
                return SafeNormalize(float3(baseNormal.rg + detailNormal.rg, baseNormal.b * detailNormal.b));
            }

            #define MAX_MIP_LEVEL 11.0

            [shader("anyhit")]
            void AnyHitMain(inout MainRayPayload payload, AttributeData attribs)
            {
            }

            [shader("closesthit")]
            void ClosestHitMain(inout MainRayPayload payload : SV_RayPayload, AttributeData attribs : SV_IntersectionAttributes)
            {
                // ----------------------------------------------------------
                // 1. Fetch and interpolate vertex attributes
                // ----------------------------------------------------------
                uint3 triangleIndices = UnityRayTracingFetchTriangleIndices(PrimitiveIndex());
                Vertex v0 = FetchVertex(triangleIndices.x);
                Vertex v1 = FetchVertex(triangleIndices.y);
                Vertex v2 = FetchVertex(triangleIndices.z);

                // Curvature
                float dnSq0 = LengthSquared(v0.normal - v1.normal);
                float dnSq1 = LengthSquared(v1.normal - v2.normal);
                float dnSq2 = LengthSquared(v2.normal - v0.normal);
                payload.curvature = sqrt(max(dnSq0, max(dnSq1, dnSq2)));

                float3 barycentricCoords = float3(1.0 - attribs.barycentrics.x - attribs.barycentrics.y,
                                                  attribs.barycentrics.x, attribs.barycentrics.y);

                Vertex v = InterpolateVertices(v0, v1, v2, barycentricCoords);

                bool isFrontFace = HitKind() == HIT_KIND_TRIANGLE_FRONT_FACE;
                float3 normalOS = isFrontFace ? v.normal : -v.normal;
                float3 normalWS = normalize(mul(normalOS, (float3x3)WorldToObject()));

                float3 direction = WorldRayDirection();
                payload.hitT = RayTCurrent();

                // ----------------------------------------------------------
                // 2. Mip level calculation
                // ----------------------------------------------------------
                float2 uvE1 = v1.uv - v0.uv;
                float2 uvE2 = v2.uv - v0.uv;
                float uvArea = abs(uvE1.x * uvE2.y - uvE2.x * uvE1.y) * 0.5f;

                float3 edge1 = v1.position - v0.position;
                float3 edge2 = v2.position - v0.position;
                float worldArea = length(cross(edge1, edge2)) * 0.5f;

                float NoRay = abs(dot(direction, normalWS));
                float a = payload.hitT * payload.mipAndCone.y;
                a *= Math::PositiveRcp(NoRay);
                a *= sqrt(uvArea / max(worldArea, 1e-10f));

                float mip = log2(a) + MAX_MIP_LEVEL;
                mip = max(mip, 0.0);
                payload.mipAndCone.x += mip;

                // ----------------------------------------------------------
                // 3. Normal mapping: main normal blended with micro normal
                // ----------------------------------------------------------
                float3 tangentWS  = normalize(mul(v.tangent.xyz, (float3x3)WorldToObject()));
                float3 bitangentWS = cross(normalWS, tangentWS) * v.tangent.w;
                half3x3 tbn = half3x3(tangentWS, bitangentWS, normalWS);

                float3 matWorldNormal = normalWS;
 
                float2 mainUV = _BaseMap_ST.xy * v.uv + _BaseMap_ST.zw;
                float4 mainNormalSample = _BumpMap.SampleLevel(sampler_BumpMap, mainUV, mip);
                float3 mainNormalTS     = UnpackNormalScale(mainNormalSample, _BumpScale);

                // Micro normal uses its own independent tiling
                float2 microUV = v.uv * _MicroNormalTiling;
                float4 microNormalSample = _MicroNormalMap.SampleLevel(sampler_MicroNormalMap, microUV, mip);
                float3 microNormalTS     = UnpackNormalScale(microNormalSample, _MicroNormalStrength);

                // Blend: micro detail on top of main normal
                float3 blendedNormalTS = BlendNormals(mainNormalTS, microNormalTS);

                matWorldNormal = normalize(TransformTangentToWorld(blendedNormalTS, tbn));
    

                // ----------------------------------------------------------
                // 4. Albedo
                // ----------------------------------------------------------
                float2 baseUV = _BaseMap_ST.xy * v.uv + _BaseMap_ST.zw;
                float3 albedo = _BaseColor.xyz * _BaseMap.SampleLevel(sampler_BaseMap, baseUV, mip).xyz;

                // ----------------------------------------------------------
                // 5. Roughness & Metallic
                // ----------------------------------------------------------
                float roughness;
                float metallic;
 
                float4 metallicSample = _MetallicGlossMap.SampleLevel(sampler_MetallicGlossMap, baseUV, mip);
                float smooth  = metallicSample.a * _Smoothness;
                roughness     = 1.0 - smooth;
                metallic      = metallicSample.r;
 

                // Skin is biological tissue, clamp metallic to near zero
                metallic = min(metallic, 0.04);

                // ----------------------------------------------------------
                // 6. Emission
                // ----------------------------------------------------------
                payload.Lemi = Packing::EncodeRgbe(float3(0, 0, 0));


                // ----------------------------------------------------------
                // 7. Fill payload
                // ----------------------------------------------------------
                uint instanceIndex = InstanceIndex();
                payload.SetInstanceIndex(instanceIndex);

                float3 worldPosition     = mul(ObjectToWorld3x4(), float4(v.position, 1.0)).xyz;
                float3 prevWorldPosition = mul(GetPrevObjectToWorldMatrix(), float4(v.position, 1.0)).xyz;
                payload.Xprev = prevWorldPosition;

                payload.N    = Packing::EncodeUnitVector(normalWS);
                payload.matN = Packing::EncodeUnitVector(matWorldNormal);

                payload.roughnessAndMetalness = Packing::Rg16fToUint(float2(roughness, metallic));
                payload.baseColor             = Packing::RgbaToUint(float4(albedo, 1.0), 8, 8, 8, 8);

                // Always mark as skin for subsurface scattering
                payload.SetFlag(FLAG_NON_TRANSPARENT | FLAG_SKIN);
            }
            ENDHLSL
        }
    }
    FallBack "Hidden/Universal Render Pipeline/FallbackError"
    // CustomEditor "UnityEditor.Rendering.Universal.ShaderGUI.LitShader"
}
