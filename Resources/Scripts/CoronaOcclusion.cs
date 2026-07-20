using Godot;

public partial class CoronaOcclusion : GeometryInstance3D
{
    [Export] public float FadeSpeed = 8.0f;
    [Export] public float MaxVisibleAlpha = 1.0f;
    [Export] public uint CollisionMask = 1; // set this to match your level geometry's collision layer

    private ShaderMaterial _material;
    private float _currentAlpha = 1.0f;

    public override void _Ready()
    {
        if (MaterialOverride != null)
        {
            MaterialOverride = (Material)MaterialOverride.Duplicate();
        }

        _material = MaterialOverride as ShaderMaterial;
        if (_material == null)
            GD.PrintErr("CoronaOcclusion: MaterialOverride must be a ShaderMaterial with a tint_color param.");
    }

    public override void _PhysicsProcess(double delta)
    {
        Camera3D camera = GetViewport().GetCamera3D();

        if (camera == null || _material == null)
            return;

        Vector3 fromPos = camera.GlobalPosition;
        Vector3 toPos = GlobalPosition;

        var spaceState = GetWorld3D().DirectSpaceState;
        var query = PhysicsRayQueryParameters3D.Create(fromPos, toPos, CollisionMask);
        query.CollideWithAreas = false;
        query.CollideWithBodies = true;

        var result = spaceState.IntersectRay(query);

        bool isOccluded = result.Count > 0;
        float targetAlpha = isOccluded ? 0.0f : MaxVisibleAlpha;

        _currentAlpha = Mathf.Lerp(_currentAlpha, targetAlpha, (float)delta * FadeSpeed);

        Color currentTint = (Color)_material.GetShaderParameter("tint_color");
        _material.SetShaderParameter("tint_color", new Color(currentTint.R, currentTint.G, currentTint.B, _currentAlpha));
    }
}