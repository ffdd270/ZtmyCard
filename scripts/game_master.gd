class_name GameMaster
extends Node

enum Phase{SET, OPEN, CLOCK, ENCHANT, BATTLE}

const MULLIGAN_COUNT = 5

signal battle_end

var players = {}
var phase = Phase.BATTLE
var ready_status = {}
@onready var chronos: Chronos = $"../Chronos"


# Called when the node enters the scene tree for the first time.
func _ready():
	multiplayer.peer_connected.connect(_on_peer_connected)
	var id = multiplayer.get_unique_id()
	players[id] = $"../Player"
	ready_status[id] = _get_init_ready_status()
	chronos.turn_done.connect(_on_chronos_turn_done)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta):
	if _is_ready_for_next_phase():
		_process_phase_transition()
		_reset_ready_status()
	if phase == Phase.OPEN:
		if players.values().all(func(x): return x.is_all_card_open()):
			next_phase_ready()


func select_card(player: Player, card: Card):
	var card_field = player.find_card_field(card)
	if card_field == Player.Field.SELECTION:
		card.selectable = false
		card.unset_hover()
		_move_card(player, card, Player.Field.ABYSS)
		player.draw_require_count += 1
		return true
	
	if card_field == Player.Field.HAND:
		if player.controllable:
			pass
		if player.battle_field_card() == null && (card.info["type"] == "character"):
			_move_card(player, card, Player.Field.BATTLE)
			player.draw_require_count += 1
		elif player.get_cards(Player.Field.SET).size() < player.setable_card_count:
			_move_card(player, card, Player.Field.SET)
			player.draw_require_count += 1
		else:
			return false
		return true
	
	_move_card(player, card, Player.Field.HAND)
	player.draw_require_count -= 1
	return true


func next_phase_ready():
	var id = multiplayer.get_unique_id()
	var next_phase = _get_next_phase()
	ready_status[id][next_phase] = true
	next_phase_ready_remote.rpc(next_phase)
	print("Player " + str(id) + " is ready for the next phase (" + Phase.keys()[next_phase] + ").")


@rpc("any_peer")
func next_phase_ready_remote(target_phase: Phase):
	var sender_id = multiplayer.get_remote_sender_id()
	ready_status[sender_id][target_phase] = true


func _move_card(player: Player, card: Card, to: Player.Field):
	var from = player.find_card_field(card)
	var idx = player.find_card_index(card, from)
	move_card.rpc(from, idx, to)


@rpc("any_peer", "call_local")
func move_card(from, idx, to):
	var player = _get_player()
	var from_field = player.card_fields[from]
	var card = from_field.cards()[idx]
	var to_field = player.card_fields[to]
	card.reparent(to_field)
	

@rpc("any_peer")
func open_card(from, idx, info):
	var player = _get_player()
	var from_field = player.card_fields[from]
	var card: Card = from_field.cards()[idx]
	card.set_info(info)
	card.show_card()


func finish_mulligan():
	var player = _get_player()
	for card in player.get_cards(Player.Field.SELECTION):
		_move_card(player, card, Player.Field.HAND)
	for card in player.get_cards(Player.Field.ABYSS):
		card.close_card()
		card.selectable = false
		_move_card(player, card, Player.Field.DECK)
	player.card_fields[Player.Field.DECK].shuffle()


func _ready_mulligan():
	var player = _get_player()
	for i in range(MULLIGAN_COUNT):
		draw_card(player, Player.Field.SELECTION)


func _get_init_ready_status():
	var result = {}
	for status in Phase.values():
		result[status] = false
	return result


# Return the player who calls this function
func _get_player() -> Player:
	var id = multiplayer.get_remote_sender_id()
	if id == 0:
		id = multiplayer.get_unique_id()
	return players[id]


func _process_phase_transition():
	phase = _get_next_phase()
	print("Current phase: " + Phase.keys()[phase])
	
	if phase == Phase.SET:
		_draw_cards()
		_set_player_hand_card_selectable(true)
	elif phase == Phase.OPEN:
		_get_player().set_battle_button_state(false)
		_set_player_hand_card_selectable(false)
		_open_cards()
	elif phase == Phase.CLOCK:
		_ready_battle()
		_update_chronos()
	elif phase == Phase.ENCHANT:
		_apply_enchant()
	elif phase == Phase.BATTLE:
		await _battle()
		_end_battle()


func draw_card(player: Player, to = Player.Field.HAND):
	var deck_cards = player.get_cards(Player.Field.DECK)
	if deck_cards.size() == 0:
		return
	
	var card: Card = deck_cards[-1]
	_move_card(player, card, to)
	card.show_card()
	if player.controllable:
		card.selectable = true


func _draw_cards():
	for player: Player in players.values():
		for i in range(player.draw_require_count):
			draw_card(player)
		player.draw_require_count = 0
		player.set_battle_button_state(true)


func _drop_card(player: Player, card: Card):
	var target_card_field = Player.Field.POWER_CHARGER \
		if int(card.info["sendToPower"]) > 0 else \
		Player.Field.ABYSS
	_move_card(player, card, target_card_field)


func _set_player_hand_card_selectable(selectable: bool):
	for card in _get_player().get_cards(Player.Field.HAND):
		card.selectable = selectable


func _open_cards():
	var player = _get_player()
	for field in [Player.Field.BATTLE, Player.Field.SET]:
		var cards = player.get_cards(field)
		for i in len(cards):
			var card: Card = cards[i]
			open_card.rpc(field, i, card.info)


func _battle():
	var total_attack_point = players.values().map(
		func(p): return p.get_attack_point(chronos.is_night())
	).reduce(
		func(a, b): return a + b
	)
	var player_hit_func: Callable
	for player: Player in players.values():
		var damage = total_attack_point - 2 * player.get_attack_point(chronos.is_night())
		if damage < 0:
			player.attack(damage)
			await player.attack_end
		else:
			player_hit_func = func(): player.hit(damage)
	player_hit_func.call()
	next_phase_ready()


func _update_chronos():
	chronos.turn.rpc(_get_player().get_clock())


func _apply_enchant():
	$EnchantProcessor.enchant_end.connect(_on_enchant_end)
	_on_enchant_end()


func _on_enchant_end():
	var player = _get_player()
	var cards = player.get_cards(Player.Field.SET)
	if cards.size() > 0:
		var card = cards[0]
		_move_card(player, card, Player.Field.ENCHANT)
		$EnchantProcessor.apply_enchant(card)
	else:
		$EnchantProcessor.enchant_end.disconnect(_on_enchant_end)
		next_phase_ready()


func _ready_battle():
	var player = _get_player()
	_swap_battle_field_card(player)
	for field in [Player.Field.BATTLE, Player.Field.SET]:
		for card in player.get_cards(field):
			card.selectable = false


func _swap_battle_field_card(player: Player):
	var set_field_cards = player.get_cards(Player.Field.SET)
	for i in set_field_cards.size():
		var card = set_field_cards[i]
		if card.info["type"] != "character":
			continue
		
		var battle_field_cards = player.get_cards(Player.Field.BATTLE)
		if battle_field_cards.size() == 0:
			return
		
		var drop_target_field = Player.Field.ABYSS
		if battle_field_cards[0].info["sendToPower"] > 0:
			drop_target_field = Player.Field.POWER_CHARGER
		move_card.rpc(Player.Field.BATTLE, 0, drop_target_field)
		move_card.rpc(Player.Field.SET, i, Player.Field.BATTLE)
		return


func _end_battle():
	for player: Player in players.values():
		player.end_battle()
	var player = _get_player()
	for card in player.get_cards(Player.Field.ENCHANT):
		_drop_card(player, card)
	battle_end.emit()


func _is_ready_for_next_phase():
	var next_phase = _get_next_phase()
	return ready_status.values().all(func(x): return x[next_phase])
	
	
func _get_next_phase() -> Phase:
	return (phase + 1) % Phase.size()


func _reset_ready_status():
	for key in ready_status.keys():
		ready_status[key][phase] = false

	
func _on_peer_connected(id):
	players[id] = $"../Opponent"
	ready_status[id] = _get_init_ready_status()
	_ready_mulligan()


func _on_chronos_turn_done():
	next_phase_ready()
