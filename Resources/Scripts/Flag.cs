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

public partial class Flag : Node3D
{
	#region========================================( Variables)======================================================//
	/*-----[ Inspector Variables ]------------------------------------------------------------------------------------*/
	[Export] public float carryHeightOffset = 1.2f;
	[Export] public string flagTeam = "";
	[Export] public float autoReturnSeconds = 20.0f;
	[Export] public float pickupCooldownSeconds = 1.0f;


	/*-----[ External Variables ]-------------------------------------------------------------------------------------*/
	[Signal] public delegate void FlagPickedUpEventHandler(Node3D player);
	[Signal] public delegate void FlagCapturedEventHandler(int capturingPeerId);
	

	/*-----[ Internal Variables ]-------------------------------------------------------------------------------------*/
	public int carrierPeerId = 0;
	public bool isDropped = false;
	private float droppedElapsed = 0.0f;
	private float pickupCooldownRemaining = 0.0f;
	private bool ctfModeActive = true;
	

	/*-----[ Reference Variables ]------------------------------------------------------------------------------------*/
	[Export] public NodePath pickupZonePath = "FlagPickupZone";
	private FlagPickupZone pickupZone;
	private Vector3 homePosition;
	private Vector3 homeRotation;
	private Node3D carrierNode;
	private Node roundManager;


	#endregion


	#region=======================================( Functions )======================================================= //
	/*-----[ Mono Functions ]-----------------------------------------------------------------------------------------*/
	public override void _Ready()
	{
		homePosition = GlobalPosition;
		homeRotation = GlobalRotation;
		pickupZone = GetNode<FlagPickupZone>(pickupZonePath);
		pickupZone.Connect(FlagPickupZone.SignalName.FlagPickedUp, new Callable(this, MethodName.OnFlagPickedUp));
	}

	public override void _Process(double delta)
	{
		UpdateModeEnabled();
		
		if (!ctfModeActive)
			return;
		
		TickPickupCooldown((float)delta);
		
		if (isDropped)
			TickAutoReturn((float)delta);
		else
			droppedElapsed = 0.0f;
		
		if (carrierPeerId == 0 || carrierNode == null)
			return;

		GlobalPosition = carrierNode.GlobalPosition + carrierNode.Basis.Y * carryHeightOffset;
		GlobalRotation = carrierNode.GlobalRotation;

		bool isLocal = carrierNode.Get("is_local_player").AsBool();
		if (!isLocal) return;

		bool isDead = carrierNode.Get("is_dead").AsBool();
		bool wantsDrop = Input.IsActionJustPressed("drop_flag");

		if (isDead || wantsDrop)
			RequestDrop();
	}

	/*-----[ Internal Functions ]-------------------------------------------------------------------------------------*/
	private void UpdateModeEnabled()
	{
		Node rm = GetRoundManager();
		bool isCtf = rm != null && rm.HasMethod("is_ctf") && rm.Call("is_ctf").AsBool();

		if (isCtf == ctfModeActive)
			return;

		ctfModeActive = isCtf;

		ctfModeActive = isCtf;

		Visible = ctfModeActive;
		pickupZone.Monitoring = ctfModeActive && ShouldMonitorPickup();
	}
	
	private Node GetRoundManager()
	{
		if (roundManager != null && GodotObject.IsInstanceValid(roundManager))
			return roundManager;

		roundManager = GetTree().Root.FindChild("RoundManager", true, false);
		return roundManager;
	}
	
	private bool ShouldMonitorPickup()
	{
		return !IsCarried() && pickupCooldownRemaining <= 0.0f;
	}
	
	private void TickPickupCooldown(float delta)
	{
		if (pickupCooldownRemaining <= 0.0f)
			return;

		pickupCooldownRemaining -= delta;

		if (pickupCooldownRemaining <= 0.0f && ShouldMonitorPickup())
			pickupZone.Monitoring = true;
	}
	
	private void TickAutoReturn(float delta)
	{
		bool isAuthority = !Multiplayer.HasMultiplayerPeer() || Multiplayer.IsServer();
		if (!isAuthority) return;

		droppedElapsed += delta;

		if (droppedElapsed < autoReturnSeconds)
			return;

		droppedElapsed = 0.0f;

		if (!Multiplayer.HasMultiplayerPeer())
			ClientApplyReturn();
		else
			Rpc(MethodName.ClientApplyReturn);
	}
	
	private void OnFlagPickedUp(Node3D player)
	{
		if (!ctfModeActive) return;
		if (carrierPeerId != 0) return; // already carried, ignore further overlaps
		if (!player.HasMethod("get_peer_id")) return;

		bool isLocal = player.Get("is_local_player").AsBool();
		if (!isLocal) return; // only the local player reports their own touch

		int peerId = player.Call("get_peer_id").AsInt32();
		string touchTeam = GetPlayerTeam(player);
        
		if (isDropped)
		{
			if (flagTeam != "" && touchTeam == flagTeam)
			{
				RequestReturn();
				return;
			}

			RequestPickup(peerId);
			return;
		}
        
		if (flagTeam != "" && touchTeam == flagTeam)
			return;

		RequestPickup(peerId);
	}
	
	private string GetPlayerTeam(Node3D player)
	{
		Variant networkManagerVariant = player.Get("network_manager");
		Node networkManager = networkManagerVariant.As<Node>();

		if (networkManager == null || !networkManager.HasMethod("get_team_for_peer"))
			return "";

		int peerId = player.Call("get_peer_id").AsInt32();
		return networkManager.Call("get_team_for_peer", peerId).AsString();
	}
	
	private void RequestPickup(int peerId)
	{
		if (!Multiplayer.HasMultiplayerPeer())
		{
			ClientApplyPickup(peerId);
			return;
		}

		RpcId(1, MethodName.ServerRequestPickup, peerId);
	}

	private void RequestDrop()
	{
		Vector3 dropPosition = GlobalPosition;

		if (!Multiplayer.HasMultiplayerPeer())
		{
			ClientApplyDrop(dropPosition);
			return;
		}

		RpcId(1, MethodName.ServerRequestDrop, carrierPeerId, dropPosition);
	}

	private void RequestReturn()
	{
		if (!Multiplayer.HasMultiplayerPeer())
		{
			ClientApplyReturn();
			return;
		}

		RpcId(1, MethodName.ServerRequestReturn);
	}

	public void RequestCapture(int peerId)
	{
		if (!Multiplayer.HasMultiplayerPeer())
		{
			ClientApplyCapture(peerId);
			return;
		}

		RpcId(1, MethodName.ServerRequestCapture, peerId);
	}
	
	
    [Rpc(MultiplayerApi.RpcMode.AnyPeer, TransferMode = MultiplayerPeer.TransferModeEnum.Reliable)]
    private void ServerRequestPickup(int peerId)
    {
        if (!Multiplayer.IsServer()) return;
        if (carrierPeerId != 0) return;

        Rpc(MethodName.ClientApplyPickup, peerId);
    }

    [Rpc(MultiplayerApi.RpcMode.AnyPeer, TransferMode = MultiplayerPeer.TransferModeEnum.Reliable)]
    private void ServerRequestDrop(int peerId, Vector3 dropPosition)
    {
        if (!Multiplayer.IsServer()) return;
        if (carrierPeerId != peerId) return;

        Rpc(MethodName.ClientApplyDrop, dropPosition);
    }

    [Rpc(MultiplayerApi.RpcMode.AnyPeer, TransferMode = MultiplayerPeer.TransferModeEnum.Reliable)]
    private void ServerRequestReturn()
    {
        if (!Multiplayer.IsServer()) return;
        if (!isDropped) return;

        Rpc(MethodName.ClientApplyReturn);
    }

    [Rpc(MultiplayerApi.RpcMode.AnyPeer, TransferMode = MultiplayerPeer.TransferModeEnum.Reliable)]
    private void ServerRequestCapture(int peerId)
    {
        if (!Multiplayer.IsServer()) return;
        if (carrierPeerId != peerId) return;

        Rpc(MethodName.ClientApplyCapture, peerId);
        RegisterCaptureScore(peerId);
    }
    
    private void RegisterCaptureScore(int peerId)
    {
        Node3D carrier = FindPlayerByPeerId(peerId);
        if (carrier == null) return;

        Node networkManager = carrier.Get("network_manager").As<Node>();
        if (networkManager == null) return;

        if (!networkManager.HasMethod("get_team_for_peer")) return;
        string capturingTeam = networkManager.Call("get_team_for_peer", peerId).AsString();

        Node rm = networkManager.Get("round_manager").As<Node>();
        if (rm == null || !rm.HasMethod("server_register_flag_capture")) return;

        rm.Call("server_register_flag_capture", peerId, capturingTeam);
    }

    [Rpc(MultiplayerApi.RpcMode.Authority, TransferMode = MultiplayerPeer.TransferModeEnum.Reliable, CallLocal = true)]
    private void ClientApplyPickup(int peerId)
    {
        carrierPeerId = peerId;
        isDropped = false;
        carrierNode = FindPlayerByPeerId(peerId);
        pickupCooldownRemaining = 0.0f;
        pickupZone.Monitoring = false;
        Visible = true;
    }

    [Rpc(MultiplayerApi.RpcMode.Authority, TransferMode = MultiplayerPeer.TransferModeEnum.Reliable, CallLocal = true)]
    private void ClientApplyDrop(Vector3 dropPosition)
    {
        carrierPeerId = 0;
        carrierNode = null;
        isDropped = true;
        droppedElapsed = 0.0f;
        pickupCooldownRemaining = pickupCooldownSeconds;
        GlobalPosition = dropPosition;
        pickupZone.Monitoring = false;
        Visible = true;
    }

    [Rpc(MultiplayerApi.RpcMode.Authority, TransferMode = MultiplayerPeer.TransferModeEnum.Reliable, CallLocal = true)]
    private void ClientApplyReturn()
    {
        carrierPeerId = 0;
        carrierNode = null;
        isDropped = false;
        droppedElapsed = 0.0f;
        pickupCooldownRemaining = 0.0f;
        GlobalPosition = homePosition;
        GlobalRotation = homeRotation;
        pickupZone.Monitoring = true;
        Visible = true;
    }

    [Rpc(MultiplayerApi.RpcMode.Authority, TransferMode = MultiplayerPeer.TransferModeEnum.Reliable, CallLocal = true)]
    private void ClientApplyCapture(int peerId)
    {
        carrierPeerId = 0;
        carrierNode = null;
        isDropped = false;
        droppedElapsed = 0.0f;
        pickupCooldownRemaining = 0.0f;
        GlobalPosition = homePosition;
        GlobalRotation = homeRotation;
        pickupZone.Monitoring = true;
        Visible = true;

        EmitSignal(SignalName.FlagCaptured, peerId);
    }

    private Node3D FindPlayerByPeerId(int peerId)
    {
        foreach (Node node in GetTree().GetNodesInGroup("players"))
        {
            if (node is Node3D player3D && player3D.HasMethod("get_peer_id"))
            {
                if (player3D.Call("get_peer_id").AsInt32() == peerId)
                    return player3D;
            }
        }

        return null;
    }


	/*-----[ External Functions ]-------------------------------------------------------------------------------------*/
	public bool IsCarried()
	{
		return carrierPeerId != 0;
	}


	#endregion
}

