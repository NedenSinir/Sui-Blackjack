module blackjack::table{
    use sui::transfer;
    use sui::sui::SUI;
    use sui::coin::{Self, Coin};
    use sui::object::{Self, UID};
    use sui::balance::{Self, Balance};
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Table, Self};
    use std::vector;
    use blackjack::drand_lib::{derive_randomness, verify_drand_signature, safe_selection};


    const EPoolIsNotSufficient: u64 = 1;
    const EGameTableAlreadyFull: u64 = 2;
    const EGameIsStillActive: u64 = 3;
    const EInvalidTurn: u64 = 4;
    const ENoPlayerPresent: u64 = 5;
    const EInvalidPlayer: u64 = 6;
    const ECompeletedDraws:u64 =7;

    const SGameCreated:u64 = 0;
    const SGameStarted:u64 = 1;
    const SGameEnded:u64 = 2;
    const SPaymentsCompeleted:u64 = 3;

    const CARDS:vector<u64> = vector[1,2,3,4,5,6,7,8,9,10,11,12,13];



    struct GameTableOwnerCap has key { id: UID }
    struct Player has key,store {
         id: UID
    }

    struct GameTable<phantom COIN> has key {
        id: UID,
        max_players:u64,
        max_bet: u64,
        pool_balance:Balance<COIN>,
        players:vector<address>,
        turn:u64,
        round:u64,
        game_state:u64,
        player_bets: Table<address, Balance<COIN>>,
        table_cards: Table<u64, vector<u64>>

    }




    public entry fun create<COIN>(max_players:u64,round:u64,coin_payment: &mut Coin<COIN>,max_bet:u64,ctx: &mut TxContext) {

        let required_amount = ((max_players as u64) * 25 * max_bet)/10;
        assert!(coin::value(coin_payment) >= required_amount, EPoolIsNotSufficient);
        let id = object::new(ctx);
        let empty_table = table::new<address, Balance<COIN>>(ctx);
        let empty_table2 = table::new<u64, vector<u64>>(ctx);
        let pool_balance:Balance<COIN> = balance::zero();
        let coin_balance = coin::balance_mut(coin_payment);
        let paid = balance::split(coin_balance, required_amount);
        balance::join(&mut pool_balance, paid);



        let owner_cap = GameTableOwnerCap{
            id:object::new(ctx)
        };

        transfer::share_object(GameTable<COIN> { 
            id, 
            max_players:max_players,
            player_bets:empty_table,
            max_bet,
            pool_balance,
            turn:0,
            round,
            game_state:0,
            players:vector::empty<address>(),
            table_cards:empty_table2
        });

        transfer::transfer(owner_cap,tx_context::sender(ctx))

        
    }

    public entry fun join_table<COIN>(game_table: &mut GameTable<COIN>,bet_amount:u64,bet_payment:&mut Coin<COIN>,
 ctx: &mut TxContext) {
        let curr_length =  vector::length<address>(&game_table.players);
        assert!(game_table.game_state == SGameCreated,EGameIsStillActive);
        assert!(curr_length+1 <= game_table.max_players,EGameTableAlreadyFull);
        let player_balance = balance::zero();
        let coin_balance = coin::balance_mut(bet_payment);
        let paid = balance::split(coin_balance, bet_amount);
        balance::join(&mut player_balance, paid);
        vector::push_back<address>(&mut game_table.players,tx_context::sender(ctx));
        table::add(&mut game_table.player_bets,tx_context::sender(ctx),player_balance)   


    }
    public entry fun end_game<COIN>(_:&GameTableOwnerCap,game_table: &mut GameTable<COIN>,ctx:&mut TxContext){
        assert!(game_table.game_state == SGameEnded,EInvalidTurn);
        let dealer_sum = get_dealer_card_sum(game_table,ctx);


        let curr_player_index = 0;
        while(curr_player_index+1 <= game_table.max_players){
            
            let curr_card_sum = get_player_card_sum(game_table,curr_player_index+1,ctx);  
            let curr_player = *vector::borrow(&game_table.players,curr_player_index);
            let player_bet = table::borrow_mut(&mut game_table.player_bets,curr_player);
            let amount = balance::value(player_bet);


            if(curr_card_sum>dealer_sum){
                if(curr_card_sum ==21){
                    let back:Coin<COIN> = coin::take(player_bet, amount, ctx);
                    let double:Coin<COIN> = coin::take(&mut game_table.pool_balance, (amount*15)/10, ctx);
                    transfer::public_transfer(back, tx_context::sender(ctx));
                    transfer::public_transfer(double, tx_context::sender(ctx));



                }else{
                    let back:Coin<COIN> = coin::take(player_bet, amount, ctx);
                    let double:Coin<COIN> = coin::take(&mut game_table.pool_balance, amount, ctx);
                    transfer::public_transfer(back, tx_context::sender(ctx));
                    transfer::public_transfer(double, tx_context::sender(ctx));


                }
            }else if(curr_card_sum < dealer_sum){

                let pool_balance: &mut Balance<COIN> =  &mut game_table.pool_balance;
                balance::join<COIN>(pool_balance, balance::withdraw_all(player_bet));
                


            }else{
                let amount = balance::value(player_bet);
                let back:Coin<COIN> = coin::take(player_bet, amount, ctx);
                transfer::public_transfer(back, tx_context::sender(ctx));

            };
            
            curr_player_index = curr_player_index+1;

        };
        game_table.game_state = SPaymentsCompeleted



    }

    public entry fun start_game<COIN>(_:&GameTableOwnerCap,game_table: &mut GameTable<COIN>,drand_sig: vector<u8>, drand_prev_sig: vector<u8>,_ctx:&mut TxContext){
        
        verify_drand_signature(drand_sig, drand_prev_sig, game_table.round);
        assert!(vector::length(&game_table.players) !=0,ENoPlayerPresent);
        let digest = derive_randomness(drand_sig);
        let curr_player = 0;
        let second_tour = false;
        while(curr_player <= game_table.max_players){
            
            let selected_card =*vector::borrow(&CARDS,safe_selection(vector::length(&CARDS), &digest));
            table::add(&mut game_table.table_cards,curr_player,vector[selected_card]);
            
            if(curr_player == vector::length(&game_table.players) && second_tour ==false){
                    curr_player=0;
                    second_tour = true;
            };
            curr_player = curr_player+1;
            

        };

        game_table.game_state = SGameStarted;
        game_table.turn = 1;

    }

    public entry fun open_dealer_card<COIN>(_:&GameTableOwnerCap,game_table: &mut GameTable<COIN>,drand_sig: vector<u8>, drand_prev_sig: vector<u8>,_ctx:&mut TxContext){
        
        verify_drand_signature(drand_sig, drand_prev_sig, game_table.round);

        let digest = derive_randomness(drand_sig);
        let dealer_sum = get_dealer_card_sum(game_table,_ctx);
        assert!(dealer_sum < 21,ECompeletedDraws);
        while(dealer_sum < 21){
            let selected_card =*vector::borrow(&CARDS,safe_selection(vector::length(&CARDS), &digest));
            let dealer_cards:&mut vector<u64> = table::borrow_mut(&mut game_table.table_cards, 0);
            vector::push_back<u64>(dealer_cards,selected_card);

        };
        game_table.game_state = SGameEnded;

            

    }
    public entry fun player_draw_card<COIN>(game_table: &mut GameTable<COIN>,ctx: &mut TxContext,drand_sig: vector<u8>,_ctx:&mut TxContext){
        let curr_turn =  game_table.turn;
        
        assert!(game_table.turn != 0,EInvalidTurn);
        let digest = derive_randomness(drand_sig);
        correct_player(game_table,ctx);
        can_player_draw(game_table,ctx);
        let selected_card =*vector::borrow(&CARDS,safe_selection(vector::length(&CARDS), &digest));
        let player_cards:&mut vector<u64> = table::borrow_mut(&mut game_table.table_cards, 0);
        vector::push_back<u64>(player_cards,selected_card);
        
        let card_sum =get_player_card_sum(game_table,curr_turn+1,ctx);
        if(card_sum >= 21){
            next_trun_player(game_table,ctx);
        }
    }
    
    public entry fun next_trun_player<COIN>(game_table: &mut GameTable<COIN>,ctx: &mut TxContext){
        let curr_length = &vector::length(&game_table.players);
        let curr_turn =  &game_table.turn;
        assert!(game_table.turn != 0,EInvalidTurn);
        correct_player(game_table,ctx);

        if(curr_length == curr_turn){
            game_table.turn= 0;

        }else{
            game_table.turn = game_table.turn +1;
        }


    }
    
    
     public entry fun next_turn_dealer<COIN>(_:&GameTableOwnerCap,game_table: &mut GameTable<COIN>,_ctx: &mut TxContext){
        assert!(game_table.turn == 0,EInvalidTurn);
        game_table.turn=1;

    }


    public entry fun withdraw_pool<COIN>(_:&GameTableOwnerCap,game_table: &mut GameTable<COIN>,ctx: &mut TxContext){
        assert!(game_table.game_state == SPaymentsCompeleted,EGameIsStillActive);
        let amount = balance::value(&game_table.pool_balance);
        let leftovers:Coin<COIN> = coin::take(&mut game_table.pool_balance, amount, ctx);
        transfer::public_transfer(leftovers, tx_context::sender(ctx))
    }


    //can disctinct game table cap withdraw another identical game's profits?




   



    




    fun correct_player<COIN>(game_table:&GameTable<COIN>,ctx: &TxContext){
                let curr_turn = &game_table.turn;
                let curr_player = vector::borrow(&game_table.players,(*curr_turn-1));
                assert!(curr_player == &tx_context::sender(ctx),EInvalidPlayer);

    }
    fun can_player_draw<COIN>(game_table:&GameTable<COIN>,_ctx: &TxContext){
        let curr_turn =  game_table.turn;        
        let curr_player = curr_turn +1;
        let curr_player_cards = table::borrow(&game_table.table_cards,curr_player);
        let curr_length = table::length(&game_table.table_cards);
        let card_index = 0;
        let card_sum =0;
        while(card_index < curr_length){
            let curr_card = *vector::borrow(curr_player_cards,card_index);
            card_sum = card_sum + curr_card;
            card_index = card_index+1;

        };
                
        assert!(card_sum <= 21,EInvalidPlayer);

    }
    fun get_player_card_sum<COIN>(game_table:&GameTable<COIN>,player_index:u64,ctx: &TxContext):u64{
        let curr_player = player_index;
        let curr_player_cards = table::borrow(&game_table.table_cards,curr_player);
        let curr_length = table::length(&game_table.table_cards);
        let card_index = 0;
        let card_sum =0;
        while(card_index < curr_length){
            let curr_card = *vector::borrow(curr_player_cards,card_index);
            card_sum = card_sum + curr_card;
            card_index = card_index+1;

        };
        card_sum
    }
    fun get_dealer_card_sum<COIN>(game_table:&GameTable<COIN>,ctx: &TxContext):u64{
        let curr_player = 0;
        let curr_player_cards = table::borrow(&game_table.table_cards,curr_player);
        let curr_length = table::length(&game_table.table_cards);
        let card_index = 0;
        let card_sum =0;
        while(card_index < curr_length){
            let curr_card = *vector::borrow(curr_player_cards,card_index);
            card_sum = card_sum + curr_card;
            card_index = card_index+1;

        };
        card_sum
    }
    fun closing_round(round: u64): u64 {
        round - 2
    }

}