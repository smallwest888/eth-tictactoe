// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

contract TicTacToe {
    enum Cell { Empty, X, O }
    enum State { Waiting, Playing, Draw, WinX, WinO }

    uint256 public constant MOVE_TIMEOUT = 60; // 60 秒未操作则超时
    uint256 public constant feeBps = 250; // 2.5%
    address public immutable dev;

    // 简易可重入保护
    bool private locked;
    modifier nonReentrant() {
        require(!locked, "reentrancy");
        locked = true;
        _;
        locked = false;
    }

    struct Game {
        address playerX;
        address playerO;
        uint256 bet;
        uint256 prizePool;
        Cell[3][3] board;
        address turn;
        State state;
        bool paid;
        uint256 lastMoveTime; // 上次落子/加入时间，用于超时判定
    }

    uint256 public gameCount;
    mapping(uint256 => Game) private games;

    event GameCreated(uint256 indexed gameId, address indexed playerX, uint256 bet);
    event GameJoined(uint256 indexed gameId, address indexed playerO, uint256 bet);
    event MoveMade(uint256 indexed gameId, address indexed player, uint8 x, uint8 y, Cell cell);
    event GameEnded(uint256 indexed gameId, State result, address winner, uint256 payout, uint256 devFee);
    event Surrendered(uint256 indexed gameId, address indexed player);
    event Timeout(uint256 indexed gameId, address indexed loser);

    /// @param _dev 手续费接收账户；传 address(0) 则使用部署者作为 Dev
    constructor(address _dev) {
        dev = _dev == address(0) ? msg.sender : _dev;
    }

    // Create Game
    function createGame() external payable returns (uint256 gameId) {
        require(msg.value > 0, "bet=0");
        gameId = ++gameCount;
        Game storage g = games[gameId];
        g.playerX = msg.sender;
        g.bet = msg.value;

        g.prizePool = msg.value;
        g.depositX = msg.value;

        g.turn = msg.sender;
        g.state = State.Waiting;
        emit GameCreated(gameId, msg.sender, msg.value);
    }

    // join Game
    function joinGame(uint256 gameId) external payable {
        Game storage g = games[gameId];
        require(g.playerX != address(0), "no game");
        require(g.state == State.Waiting, "not joinable");
        require(g.playerO == address(0), "full");
        require(msg.sender != g.playerX, "X cannot join again");
        require(msg.value == g.bet, "bet must be matched");

        g.playerO = msg.sender;
        g.prizePool += msg.value;
        g.depositO += msg.value;

        g.state = State.Playing;
        g.lastMoveTime = block.timestamp;

        emit GameJoined(gameId, msg.sender, msg.value);
    }

    //Initiate a raise: the opponent must match the total deposit before the deadline, otherwise they lose the game
    function raise(uint256 gameId) external payable{
        Game storage g = games[gameId];

        require(g.state == State.Playing, "not playing");
        require(!g.paid, "already paid");
        require(!g.raiseActive, "raise already active");
        require(msg.value > 0, "amount > 0");
        require(msg.sender == g.playerX || msg.sender == g.playerO, "not a player");
        require(msg.sender == g.turn, "not your turn");

        // Add funds to the prize pool and update deposit accounting 
        g.prizePool += msg.value;

        if (msg.sender == g.playerX) {
            g.depositX += msg.value;
            g.targetDeposit = g.depositX;
        } else {
            g.depositO += msg.value;
            g.targetDeposit = g.depositO;
        }

        g.raiseActive = true;
        g.raiser = msg.sender;
        g.raiseDeadline = block.timestamp + 60;

        emit Raised(gameId, msg.sender, msg.value, g.targetDeposit, g.raiseDeadline);
    }
    
    // match a raise: the opponent must exactly match the targetDeposit
    function matchRaise(uint256 gameId) external payable{
        Game storage g = games[gameId];

        require(g.state == State.Playing, "not playing");
        require(!g.paid, "already paid");
        require(g.raiseActive, "no active raise");
        require(block.timestamp <= g.raiseDeadline, "too late");
        require(msg.sender == g.playerX || msg.sender == g.playerO, "not a player");
        require(msg.sender != g.raiser, "raiser cannot match");

        // Compute the exact amount required to match the raiser's total deposit
        uint256 need;
        if(msg.sender == g.playerX){
            require(g.targetDeposit >= g.depositX, "internal error");
            need = g.targetDeposit - g.depositX;
            require(msg.value == need, "must match exactly");
            g.depositX += msg.value;
        } else {
            require(g.targetDeposit >= g.depositO, "internal error");
            need = g.targetDeposit - g.depositO;
            require(msg.value == need, "must match exactly");
            g.depositO += msg.value;
        }

        g.prizePool += msg.value;

        // clear raise state 
        g.raiseActive = false;
        g.raiser = address(0);
        g.targetDeposit = 0;
        g.raiseDeadline = 0;

        emit RaiseMatched(gameId, msg.sender, msg.value, g.depositX, g.depositO);

    }

    // If the opponent failes to match before the deaedline, they lose and the raiser wins the game
    function lose(uint256 gameId) external{
        Game storage g = games[gameId];

        require(g.state == State.Playing, "not playing");
        require(!g.paid, "already paid");
        require(g.raiseActive, "no active raise");
        require(block.timestamp > g.raiseDeadline, "not expired");

        address winner = g.raiser;
        require(winner != address(0), "no rasier");
        address loser = (winner == g.playerX) ? g.playerO : g.playerX;

        // End the game
        g.state = (winner == g.playerX) ? State.WinX : State.WinO;

        // clear raise state 
        g.raiseActive = false;
        g.raiser = address(0);
        g.targetDeposit = 0;
        g.raiseDeadline = 0;

        emit Loss(gameId, loser, winner);
        payoutWinner(gameId, g, winner);

    }

    

    // Move
    function move(uint256 gameId, uint8 x, uint8 y) external nonReentrant {
        Game storage g = games[gameId];
        require(g.state == State.Playing, "the game is not active");
        require(!g.paid, "already paid");
        require(msg.sender == g.turn, "it is not your turn");
        require(x < 3 && y < 3, "out of bounds");
        require(g.board[x][y] == Cell.Empty, "taken");

        Cell placed;
        if (msg.sender == g.playerX) {
            placed = Cell.X;
        } else {
            require(msg.sender == g.playerO, "not player");
            placed = Cell.O;
        }

        g.board[x][y] = placed;
        g.lastMoveTime = block.timestamp;
        emit MoveMade(gameId, msg.sender, x, y, placed);

        if (isWin(g.board, Cell.X)) {
            g.state = State.WinX;
            _payoutWinner(g, g.playerX, gameId);
            return;
        }
        if (isWin(g.board, Cell.O)) {
            g.state = State.WinO;
            _payoutWinner(g, g.playerO, gameId);
            return;
        }
        if (isDraw(g.board)) {
            g.state = State.Draw;
            _refundDrawWithFee(g, gameId);
            return;
        }

        // 若对手已无获胜可能，直接判当前玩家胜
        Cell opponentCell = (placed == Cell.X) ? Cell.O : Cell.X;
        if (!canPlayerStillWin(g.board, opponentCell)) {
            g.state = (placed == Cell.X) ? State.WinX : State.WinO;
            address winner = (placed == Cell.X) ? g.playerX : g.playerO;
            _payoutWinner(g, winner, gameId);
            return;
        }

        g.turn = (g.turn == g.playerX) ? g.playerO : g.playerX;
    }

    /// 认输：发起方按平局处理，双方退还赌注（不扣手续费）
    function surrender(uint256 gameId) external nonReentrant {
        Game storage g = games[gameId];
        require(g.state == State.Playing, "not playing");
        require(msg.sender == g.playerX || msg.sender == g.playerO, "not player");
        g.state = State.Draw;
        emit Surrendered(gameId, msg.sender);
        _refundDrawNoFee(g, gameId);
    }

    /// 超时：60 秒内未操作，当前回合方判负，对方获胜
    function claimTimeout(uint256 gameId) external nonReentrant {
        Game storage g = games[gameId];
        require(g.state == State.Playing, "not playing");
        require(block.timestamp >= g.lastMoveTime + MOVE_TIMEOUT, "not timeout yet");
        address loser = g.turn;
        address winner = (g.turn == g.playerX) ? g.playerO : g.playerX;
        g.state = (g.turn == g.playerX) ? State.WinO : State.WinX;
        emit Timeout(gameId, loser);
        _payoutWinner(g, winner, gameId);
    }

    // 兜底：触发 payout/refund（正常对局已自动结算）
    function claim(uint256 gameId) external nonReentrant {
        Game storage g = games[gameId];
        require(!g.paid, "already paid");
        require(g.state == State.Draw || g.state == State.WinX || g.state == State.WinO, "not finished");
        if (g.state == State.WinX) _payoutWinner(g, g.playerX, gameId);
        else if (g.state == State.WinO) _payoutWinner(g, g.playerO, gameId);
        else _refundDrawWithFee(g, gameId);
    }

    // frontend
    function getGame(uint256 gameId) external view returns (
        address playerX,
        address playerO,
        uint256 bet,
        uint256 prizePool,
        address turn,
        State state,
        bool paid,
        uint256 lastMoveTime
    ) {
        Game storage g = games[gameId];
        return (g.playerX, g.playerO, g.bet, g.prizePool, g.turn, g.state, g.paid, g.lastMoveTime);
    }

    function getCell(uint256 gameId, uint8 x, uint8 y) external view returns (Cell) {
        require(x < 3 && y < 3, "out of bounds");
        return games[gameId].board[x][y];
    }

    function getBoard(uint256 gameId) external view returns (uint8[9] memory flat) {
        Game storage g = games[gameId];
        uint8 k = 0;
        for (uint8 i = 0; i < 3; i++) {
            for (uint8 j = 0; j < 3; j++) {
                flat[k++] = uint8(g.board[i][j]);
            }
        }
    }

    // payout
    function _payoutWinner(Game storage g, address winner, uint256 gameId) internal {
        if (g.paid) return;
        g.paid = true;
        uint256 amount = g.prizePool;

        // effects first
        g.prizePool = 0;
        g.depositX = 0;
        g.depositO = 0;

        uint256 fee = (amount * feeBps) / 10000;
        uint256 remaining = amount - fee;

        if (fee > 0) {
            (bool fm, ) = dev.call{value: fee}("");
            require(fm, "fee transfer failed");
        }
        (bool ok, ) = payable(winner).call{value: remaining}("");
        require(ok, "payout failed");
        emit GameEnded(gameId, g.state, winner, remaining, fee);
    }

    function _refundDrawWithFee(Game storage g, uint256 gameId) internal {
        if (g.paid) return;
        g.paid = true;
        uint256 amount = g.prizePool;
        g.prizePool = 0;

        uint256 fee = (amount * feeBps) / 10000;
        uint256 remaining = amount - fee;
        if (fee > 0) {
            (bool fm, ) = dev.call{value: fee}("");
            require(fm, "fee transfer failed");
        }
        uint256 half = remaining / 2;
        (bool okX, ) = payable(g.playerX).call{value: half}("");
        require(okX, "refund X failed");
        (bool okO, ) = payable(g.playerO).call{value: remaining - half}("");
        require(okO, "refund O failed");
        emit GameEnded(gameId, g.state, address(0), remaining, fee);
    }

    function _refundDrawNoFee(Game storage g, uint256 gameId) internal {
        if (g.paid) return;
        g.paid = true;
        uint256 b = g.bet;
        g.prizePool = 0;
        (bool okX, ) = payable(g.playerX).call{value: b}("");
        require(okX, "refund X failed");
        (bool okO, ) = payable(g.playerO).call{value: oAmt}("");
        require(okO, "refund O failed");
        emit GameEnded(gameId, g.state, address(0), b * 2, 0);
    }

    /// 判断某方是否还有可能连成一线（任意一行/列/对角无对方棋子即有可能）
    function canPlayerStillWin(Cell[3][3] memory b, Cell c) internal pure returns (bool) {
        Cell opp = (c == Cell.X) ? Cell.O : Cell.X;
        for (uint8 i = 0; i < 3; i++) {
            if (b[i][0] != opp && b[i][1] != opp && b[i][2] != opp) return true;
            if (b[0][i] != opp && b[1][i] != opp && b[2][i] != opp) return true;
        }
        if (b[0][0] != opp && b[1][1] != opp && b[2][2] != opp) return true;
        if (b[0][2] != opp && b[1][1] != opp && b[2][0] != opp) return true;
        return false;
    }

    // Win / Draw Detect
    function isWin(Cell[3][3] memory b, Cell c) internal pure returns (bool) {
        for (uint8 i = 0; i < 3; i++) {
            if (b[i][0] == c && b[i][1] == c && b[i][2] == c) return true;
            if (b[0][i] == c && b[1][i] == c && b[2][i] == c) return true;
        }
        if (b[0][0] == c && b[1][1] == c && b[2][2] == c) return true;
        if (b[0][2] == c && b[1][1] == c && b[2][0] == c) return true;
        return false;
    }

    function isDraw(Cell[3][3] memory b) internal pure returns (bool) {
        for (uint8 i = 0; i < 3; i++) {
            for (uint8 j = 0; j < 3; j++) {
                if (b[i][j] == Cell.Empty) return false;
            }
        }
        return true;
    }
}

