-module(elixir_clauses).
-export([match/3, assigns/3, assigns_blocks/4, assigns_blocks/5, extract_guards/1]).
-include("elixir.hrl").

% Function for translating assigns.

assigns(Fun, Args, Scope) ->
  { Result, NewScope } = Fun(Args, Scope#elixir_scope{assign=true}),
  { Result, NewScope#elixir_scope{assign=false, temp_vars=[] } }.

% Handles assigns with guards

assigns_blocks(Fun, BareArgs, Exprs, S) ->
  { Args, Guards } = extract_guards(BareArgs),
  assigns_blocks(Fun, Args, Exprs, Guards, S).

assigns_blocks(Fun, Args, Exprs, Guards, S) ->
  { TArgs, SA }    = elixir_clauses:assigns(Fun, Args, S),
  { TGuards, SG }  = elixir_translator:translate(Guards, SA#elixir_scope{guard=true}),
  { TExprs, SE }   = elixir_translator:translate(Exprs, SG#elixir_scope{guard=false}),

  % Properly listify args
  case is_list(TArgs) of
    true  -> FArgs = TArgs;
    false -> FArgs = [TArgs]
  end,

  % Properly listify guards
  FGuards = case TGuards of
    [] -> [];
    _  -> [TGuards]
  end,

  % Uncompact expressions from the block.
  case TExprs of
    { block, _, FExprs } -> [];
    _ -> FExprs = TExprs
  end,

  { { clause, 0, FArgs, FGuards, FExprs }, SE }.

% Extract guards from the given expression.

extract_guards({ '|', _, [Left, Right] }) -> { Left, [Right] };
extract_guards(Else) -> { Else, [] }.

% Function for translating macros with match style
% clauses like case, try and receive.

match(Line, Clauses, RawS) ->
  S = RawS#elixir_scope{clause_vars=dict:new()},
  DecoupledClauses = decouple_clauses(Clauses, []),

  case DecoupledClauses of
    [DecoupledClause] ->
      { TDecoupledClause, TS } = translate_each(DecoupledClause, S),
      { [TDecoupledClause], TS };
    _ ->
      % Transform tree just passing the variables counter forward
      % and storing variables defined inside each clause.
      Transformer = fun(X, {Acc, CV}) ->
        { TX, TAcc } = translate_each(X, Acc),
        { TX, { umergec(S, TAcc), [TAcc#elixir_scope.clause_vars|CV] } }
      end,

      { TClauses, { TS, RawCV } } = lists:mapfoldl(Transformer, {S, []}, DecoupledClauses),

      % Now get all the variables defined inside each clause
      CV = lists:reverse(RawCV),
      NewVars = lists:umerge([lists:sort(dict:fetch_keys(X)) || X <- CV]),

      case NewVars of
        [] -> { TClauses, TS };
        _  ->
          % Create a new scope that contains a list of all variables
          % defined inside all the clauses. It returns this new scope and
          % a list of tuples where the first element is the variable name,
          % the second one is the new pointer to the variable and the third
          % is the old pointer.
          { FinalVars, FS } = lists:mapfoldl(fun normalize_vars/2, TS, NewVars),

          % Defines a tuple that will be used as left side of the match operator
          LeftTuple = { tuple, Line, [{var, Line, NewValue} || {_, NewValue,_} <- FinalVars] },
          { StorageVar, SS } = elixir_tree_helpers:build_var_name(Line, FS),

          % Expand all clauses by adding a match operation at the end that assigns
          % variables missing in one clause to the others.
          Expander = fun(Clause, Counter) ->
            ClauseVars = lists:nth(Counter, CV),
            RightTuple = [normalize_clause_var(Var, OldValue, ClauseVars) || {Var, _, OldValue} <- FinalVars],

            AssignExpr = { match, Line, LeftTuple, { tuple, Line, RightTuple } },
            ClauseExprs = element(5, Clause),
            [Final|RawClauseExprs] = lists:reverse(ClauseExprs),

            % If the last sentence has a match clause, we need to assign its value
            % in the variable list. If not, we insert the variable list before the
            % final clause in order to keep it tail call optimized.
            FinalClauseExprs = case has_match_tuple(Final) of
              true ->
                StorageExpr = { match, Line, StorageVar, Final },
                [StorageVar,AssignExpr,StorageExpr|RawClauseExprs];
              false ->
                [Final,AssignExpr|RawClauseExprs]
            end,

            FinalClause = setelement(5, Clause, lists:reverse(FinalClauseExprs)),
            { FinalClause, Counter + 1 }
          end,

          { FClauses, _ } = lists:mapfoldl(Expander, 1, TClauses),
          { FClauses, SS }
      end
  end.

% Decouple clauses. A clause is a key-value pair. If the value is an array,
% it is broken into several other key-value pairs with the same key. This
% process is only valid for :match and :catch keys (as they are the only
% that supports many clauses)
%
% + An array. Which means several expressions were given. Valid only for match, elsif, catch.
% + Any other expression.
%
decouple_clauses([{Key,Value}|T], Clauses) when is_list(Value), Key == match orelse Key == 'catch' ->
  Final = lists:foldl(fun(X, Acc) -> [{Key,X}|Acc] end, Clauses, Value),
  decouple_clauses(T, Final);

% TODO: Raise a better message.
decouple_clauses([{Key,Value}|T], Clauses) when is_list(Value) ->
  error({invalid_many_clauses_for_key, Key});

decouple_clauses([H|T], Clauses) ->
  decouple_clauses(T, [H|Clauses]);

decouple_clauses([], Clauses) ->
  lists:reverse(Clauses).

% Handle each key/value clause pair and translate them accordingly.

% Extract clauses from block.
translate_each({Key,{block,_,Exprs}}, S) ->
  translate_each({Key,Exprs}, S);

% Wrap each clause in a list. The first item in the list usually express a condition.
translate_each({Key,Expr}, S) when not is_list(Expr) ->
  translate_each({Key,[Expr]}, S);

% Clauses must return at least two elements.
translate_each({Key,[Expr]}, S) ->
  translate_each({Key,[Expr, nil]}, S);

% Handle assign other clauses.
translate_each({Key,[Condition|Exprs]}, S) when Key == match; Key == 'catch'; Key == 'after' ->
  assigns_blocks(fun elixir_translator:translate_each/2, Condition, Exprs, S);

% TODO: Raise a better message.
translate_each({Key,Value}, S) ->
  error({invalid_key_for_clause, Key}).

% Check if the given expression is a match tuple.
% This is a small optimization to allow us to change
% existing assignments instead of creating new ones every time.

has_match_tuple({match, _, _, _}) ->
  true;

has_match_tuple(H) when is_tuple(H) ->
  has_match_tuple(tuple_to_list(H));

has_match_tuple(H) when is_list(H) ->
  lists:any(fun has_match_tuple/1, H);

has_match_tuple(H) -> false.

% Normalize the given var checking its existence in the scope var dictionary.

normalize_vars(Var, #elixir_scope{vars=Dict} = S) ->
  { { _, _, NewValue }, NS } = elixir_tree_helpers:build_var_name(0, S),
  FS = NS#elixir_scope{vars=dict:store(Var, NewValue, Dict)},

  Expr = case dict:find(Var, Dict) of
    { ok, OldValue } -> { var, 0, OldValue };
    error -> { atom, 0, nil }
  end,

  { { Var, NewValue, Expr }, FS }.

% Normalize a var by checking if it was defined in the clause.
% If so, use it, otherwise use from main scope.

normalize_clause_var(Var, OldValue, ClauseVars) ->
  case dict:find(Var, ClauseVars) of
    { ok, ClauseValue } -> { var, 0, ClauseValue };
    error -> OldValue
  end.

% Merge variable counters.

umergec(S1, S2) ->
  S1#elixir_scope{counter=S2#elixir_scope.counter}.