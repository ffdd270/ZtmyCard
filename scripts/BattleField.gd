extends Area2D

var card_set = null


# Called when the node enters the scene tree for the first time.
func _ready():
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass


func set_card(card):
	card_set = card
	card.position = Vector2()
	add_child(card)


func unset_card(card):
	if card == card_set:
		card_set = null
		remove_child(card)
