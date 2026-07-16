//==========================================( Neverway 2026 )=========================================================//
// Author
//
//
// Contributors
//
//
//====================================================================================================================//


using Godot;
using System;

public partial class Hud : Control
{
	#region========================================( Variables)======================================================//
	/*-----[ Inspector Variables ]------------------------------------------------------------------------------------*/
	[Export] public Color grappleDarkColor = new Color(0.25f, 0.25f, 0.25f);
	[Export] public Color grappleAvailableColor = Colors.White;
	[Export] public Color grappleLockedColor = new Color(0.2f, 0.5f, 1.0f);

	/*-----[ External Variables ]-------------------------------------------------------------------------------------*/


	/*-----[ Internal Variables ]-------------------------------------------------------------------------------------*/
	public float currentHp = 100;
	public float maxHp = 100;
	private GroundState lastGroundState = (GroundState)(-1);
	private Node playerRoot;

	private enum GroundState
	{
		FreeFloat,
		PushAvailable,
		GroundLockEnable,
		GroundLockDisable
	}


	/*-----[ Reference Variables ]------------------------------------------------------------------------------------*/
	[Export] public TextureProgressBar healthBar;
	[Export] public Label healthText;
	[Export] public Node playerHealth;
	
	[Export] public TextureRect groundStateIndicator;
	[Export] public Label groundStateText;
	[Export] public Node movementController;

	[Export] public Texture2D freeFloatIcon;
	[Export] public Texture2D pushAvailableIcon;
	[Export] public Texture2D groundLockEnableIcon;
	[Export] public Texture2D groundLockDisableIcon;
	
	[Export] public Label ammoText;
	[Export] public Label weaponText;
	[Export] public Node weaponInventory;
	
	[Export] public TextureRect grappleStateIndicator;
	[Export] public Label rangeIndicatorText;
	[Export] public Label grappleStateText;
	[Export] public TextureProgressBar grappleReelBar;
	[Export] public Node grappleController;
	
	[Export] public Label jumpForceText;
	[Export] public TextureProgressBar jumpForceBar;

	#endregion


	#region=======================================( Functions )======================================================= //
	/*-----[ Mono Functions ]-----------------------------------------------------------------------------------------*/
	public override void _Ready()
	{
		playerHealth.Connect("health_changed", Callable.From<float, float>(OnHealthChanged));
		
		weaponInventory.Connect("weapon_equipped", Callable.From<StringName, Node>(OnWeaponEquipped));

		weaponText.Text = "-";
		ammoText.Text = "-";
		
		playerRoot = FindPlayerRoot();
		Visible = false;
	}

	public override void _Process(double delta)
	{
		if (playerRoot == null) return;

		bool isLocal = playerRoot.Get("is_local_player").AsBool();
		Visible = isLocal;

		if (!isLocal) return;
		UpdateGroundStateIndicator();
		UpdateGrappleIndicator();
		UpdateJumpForceIndicator();
	}

	/*-----[ Internal Functions ]-------------------------------------------------------------------------------------*/
	private void OnHealthChanged(float current, float max)
	{
		currentHp = current;
		maxHp = max;
		SetPlayerHealth();
	}

	private void UpdateGroundStateIndicator()
	{
		GroundState groundState = ReadGroundState();
		
		if (groundState == lastGroundState) return;

		lastGroundState = groundState;
		
		groundStateIndicator.Texture = groundState switch
		{
			GroundState.FreeFloat => freeFloatIcon,
			GroundState.PushAvailable => pushAvailableIcon,
			GroundState.GroundLockEnable => groundLockEnableIcon,
			GroundState.GroundLockDisable => groundLockDisableIcon,
			_ => groundStateIndicator.Texture
		};
		
		groundStateText.Text = groundState switch
		{
			GroundState.FreeFloat => "Free Float",
			GroundState.PushAvailable => "[Space] Push",
			GroundState.GroundLockEnable => "[C] Engage Ground Lock",
			GroundState.GroundLockDisable => "[C] Disengage Ground Lock",
			_ => groundStateText.Text
		};
	}
	
	private GroundState ReadGroundState()
	{
		int movementMode = movementController.Get("movement_mode").AsInt32();

		if (movementMode == 1)
			return GroundState.GroundLockDisable;

		bool canGroundLock = movementController.Call("can_ground_lock").AsBool();

		if (canGroundLock)
			return GroundState.GroundLockEnable;

		float maxDistance = movementController.Get("surface_walk_lock_max_distance").AsSingle();
		var nearbySurface = movementController.Call("find_spawn_surface", maxDistance, -1.0f).AsGodotDictionary();

		return nearbySurface.Count > 0 ? GroundState.PushAvailable : GroundState.FreeFloat;
	}
	
	private void OnWeaponEquipped(StringName weaponId, Node weapon)
	{
		weaponText.Text = FormatWeaponName(weaponId);

		if (weapon == null)
		{
			ammoText.Text = "-";
			return;
		}

		// Resubscribe to the ammo changed event if the weapon was swapped
		weapon.Connect("ammo_changed", Callable.From<int, int>(OnAmmoChanged));

		bool usesAmmo = weapon.HasMethod("uses_ammo") && weapon.Call("uses_ammo").AsBool();

		if (!usesAmmo)
		{
			ammoText.Text = "∞";
			return;
		}

		int currentAmmo = weapon.Get("current_ammo").AsInt32();
		int reserveAmmo = weapon.Get("current_reserve").AsInt32();
		UpdateAmmoText(currentAmmo, reserveAmmo);
	}

	private void OnAmmoChanged(int currentAmmo, int reserveAmmo)
	{
		UpdateAmmoText(currentAmmo, reserveAmmo);
	}

	private void UpdateAmmoText(int current, int reserve)
	{
		ammoText.Text = $"{current}/{reserve}";
	}

	private static string FormatWeaponName(StringName weaponId)
	{
		string raw = weaponId.ToString();

		if (string.IsNullOrEmpty(raw))
			return "No Weapon";

		// Convert snake case to a normal name
		// eg something like "big_effin_gun" becomes "Big Effin Gun"
		var parts = raw.Split('_');
		for (int i = 0; i < parts.Length; i++)
		{
			if (parts[i].Length > 0)
				parts[i] = char.ToUpperInvariant(parts[i][0]) + parts[i][1..];
		}

		return string.Join(" ", parts);
	}
	
	private void UpdateGrappleIndicator()
	{
		if (grappleController == null) return;

		float lookDistance = grappleController.Call("get_camera_look_distance").AsSingle();
		rangeIndicatorText.Text = lookDistance >= 0.0f ? $"{Mathf.RoundToInt(lookDistance)}m" : "";
		
		bool locked = grappleController.Get("attached").AsBool();

		grappleReelBar.MinValue = 0.0;
		grappleReelBar.MaxValue = 1.0;
		grappleReelBar.Step = 0.001;

		if (locked)
		{
			grappleStateIndicator.Modulate = grappleLockedColor;
			grappleStateText.Text = "[Q] Release";
			grappleReelBar.Value = grappleController.Call("get_reel_ratio").AsSingle();
			return;
		}

		grappleReelBar.Value = 0.0;

		bool available = grappleController.Call("get_aim_target_info").AsGodotDictionary()["available"].AsBool();

		if (available)
		{
			grappleStateIndicator.Modulate = grappleAvailableColor;
			grappleStateText.Text = "[E] Grapple";
		}
		else
		{
			grappleStateIndicator.Modulate = grappleDarkColor;
			grappleStateText.Text = "";
		}
	}
	
	private void UpdateJumpForceIndicator()
	{
		if (movementController == null) return;

		float jumpForce = movementController.Get("jump_force").AsSingle();
		float minJumpForce = movementController.Get("min_jump_force").AsSingle();
		float maxJumpForce = movementController.Get("max_jump_force").AsSingle();

		jumpForceText.Text = $"{Mathf.RoundToInt(jumpForce)}N";

		jumpForceBar.MinValue = minJumpForce;
		jumpForceBar.MaxValue = maxJumpForce;
		jumpForceBar.Step = 0.001;
		jumpForceBar.Value = jumpForce;
	}

	
	private Node FindPlayerRoot()
	{
		Node current = GetParent();

		while (current != null)
		{
			if (current.HasMethod("get_peer_id"))
				return current;

			current = current.GetParent();
		}

		return null;
	}



	/*-----[ External Functions ]-------------------------------------------------------------------------------------*/
	public void SetPlayerHealth()
	{
		healthBar.MaxValue = maxHp;
		healthBar.Value = currentHp;
		healthText.Text = $"{(int)currentHp}/{(int)maxHp}";
	}


	#endregion
}

