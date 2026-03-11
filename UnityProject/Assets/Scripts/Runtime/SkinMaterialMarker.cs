using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

/// <summary>
/// Attach to any GameObject to mark/unmark its materials as skin for SSS.
/// Use the Inspector buttons to apply the _SKIN keyword and refresh masks.
/// </summary>
[DisallowMultipleComponent]
public class SkinMaterialMarker : MonoBehaviour
{
    private const string SKIN_KEYWORD = "_SKIN";

    [Tooltip("Also apply to all child Renderers.")]
    public bool includeChildren = false;

    public void SetAsSkin()   => ApplyKeyword(true);
    public void SetAsNormal() => ApplyKeyword(false);

    private void ApplyKeyword(bool enable)
    {
        foreach (var r in GetRenderers())
        {
            foreach (var mat in r.sharedMaterials)
            {
                if (mat == null) continue;
                if (enable)
                    mat.EnableKeyword(SKIN_KEYWORD);
                else
                    mat.DisableKeyword(SKIN_KEYWORD);
#if UNITY_EDITOR
                UnityEditor.EditorUtility.SetDirty(mat);
#endif
            }
        }

        RefreshMasks();
    }

    private static void RefreshMasks()
    {
        var urpAsset = GraphicsSettings.currentRenderPipeline as UniversalRenderPipelineAsset;
        if (urpAsset == null) return;

        // Iterate all renderer data assets to find PathTracingFeature
        var rendererDataList = urpAsset.GetType()
            .GetField("m_RendererDataList",
                System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)
            ?.GetValue(urpAsset) as ScriptableRendererData[];

        if (rendererDataList == null) return;

        foreach (var rendererData in rendererDataList)
        {
            if (rendererData == null) continue;
            foreach (var feature in rendererData.rendererFeatures)
            {
                if (feature is PathTracing.PathTracingFeature ptf)
                {
                    ptf.SetMask();
                    return;
                }
            }
        }

        Debug.LogWarning("[SkinMaterialMarker] PathTracingFeature not found in current URP renderer.");
    }

    private Renderer[] GetRenderers()
    {
        return includeChildren
            ? GetComponentsInChildren<Renderer>(true)
            : GetComponents<Renderer>();
    }
}

#if UNITY_EDITOR
[UnityEditor.CustomEditor(typeof(SkinMaterialMarker))]
public class SkinMaterialMarkerEditor : UnityEditor.Editor
{
    public override void OnInspectorGUI()
    {
        DrawDefaultInspector();

        UnityEditor.EditorGUILayout.Space(8);

        var marker = (SkinMaterialMarker)target;

        var prevColor = GUI.backgroundColor;

        GUI.backgroundColor = new Color(0.55f, 0.85f, 1.0f);
        if (GUILayout.Button("Set as Skin", GUILayout.Height(32)))
            marker.SetAsSkin();

        GUI.backgroundColor = new Color(1.0f, 0.85f, 0.55f);
        if (GUILayout.Button("Set as Normal", GUILayout.Height(32)))
            marker.SetAsNormal();

        GUI.backgroundColor = prevColor;
    }
}
#endif
