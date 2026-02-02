// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

contract TicTacToe {
    enum Cell { Empty, X, O }
    enum State { Waiting, Playing, Draw, WinX, WinO, Cancelled }

    uint256 public constant MOVE_TIMEOUT = 60; // 60s without a move => timeout
    uint256 public constant feeBps = 250; // 2.5%
    address public immutable dev;

    // easy reentrancy protection
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
        uint256 lastMoveTime; // last move/join time for timeout
        // raise state
        bool raiseActive;
        address raiser;
        uint256 targetDeposit;
        uint256 raiseDeadline;
        uint256 depositX;
        uint256 depositO;
    }

    uint256 public gameCount;
    mapping(uint256 => Game) private games;

    event GameCreated(uint256 indexed gameId, address indexed playerX, uint256 bet);
    event GameJoined(uint256 indexed gameId, address indexed playerO, uint256 bet);
    event MoveMade(uint256 indexed gameId, address indexed player, uint8 x, uint8 y, Cell cell);
    event GameEnded(uint256 indexed gameId, State result, address winner, uint256 payout, uint256 devFee);
    event Surrendered(uint256 indexed gameId, address indexed player);
    event Timeout(uint256 indexed gameId, address indexed loser);
    event Raised(uint256 indexed gameId, address indexed player, uint256 amount, uint256 targetDeposit, uint256 deadline);
    event RaiseMatched(uint256 indexed gameId, address indexed player, uint256 amount, uint256 depositX, uint256 depositO);
    event Loss(uint256 indexed gameId, address indexed loser, address indexed winner);
    event GameCancelled(uint256 indexed gameId, address indexed playerX, uint256 refund);

    /// @param _dev Fee recipient; pass address(0) to use deployer as Dev
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

    // Cancel game (creator only) when no one joined; refunds full bet
    function cancelGame(uint256 gameId) external nonReentrant {
        Game storage g = games[gameId];
        require(g.state == State.Waiting, "not waiting");
        require(g.playerO == address(0), "already joined");
        require(msg.sender == g.playerX, "not creator");
        require(!g.paid, "already paid");
        uint256 refund = g.prizePool;
        require(refund > 0, "nothing to refund");
        g.prizePool = 0;
        g.paid = true;
        g.state = State.Cancelled;
        emit GameCancelled(gameId, msg.sender, refund);
        (bool ok, ) = payable(msg.sender).call{value: refund}("");
        require(ok, "refund failed");
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

    // Raise bet during your turn
    function raise(uint256 gameId) external payable nonReentrant {
        Game storage g = games[gameId];
        require(g.state == State.Playing, "not playing");
        require(!g.paid, "already paid");
        require(!g.raiseActive, "raise active");
        require(msg.value > 0, "amount > 0");
        require(msg.sender == g.playerX || msg.sender == g.playerO, "not player");
        require(msg.sender == g.turn, "not your turn");

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
        g.lastMoveTime = block.timestamp;
        emit Raised(gameId, msg.sender, msg.value, g.targetDeposit, g.raiseDeadline);
    }

    // Match raise: opponent must match target deposit within 60s
    function matchRaise(uint256 gameId) external payable nonReentrant {
        Game storage g = games[gameId];
        require(g.state == State.Playing, "not playing");
        require(!g.paid, "already paid");
        require(g.raiseActive, "no active raise");
        require(block.timestamp <= g.raiseDeadline, "too late");
        require(msg.sender == g.playerX || msg.sender == g.playerO, "not player");
        require(msg.sender != g.raiser, "raiser cannot match");

        uint256 need;
        if (msg.sender == g.playerX) {
            require(g.targetDeposit >= g.depositX, "internal");
            need = g.targetDeposit - g.depositX;
            require(msg.value == need, "must match exactly");
            g.depositX += msg.value;
        } else {
            require(g.targetDeposit >= g.depositO, "internal");
            need = g.targetDeposit - g.depositO;
            require(msg.value == need, "must match exactly");
            g.depositO += msg.value;
        }

        g.prizePool += msg.value;
        g.raiseActive = false;
        g.raiser = address(0);
        g.targetDeposit = 0;
        g.raiseDeadline = 0;
        g.lastMoveTime = block.timestamp;
        emit RaiseMatched(gameId, msg.sender, msg.value, g.depositX, g.depositO);
    }

    // If opponent fails to match before deadline, raiser wins
    function lose(uint256 gameId) external nonReentrant {
        Game storage g = games[gameId];
        require(g.state == State.Playing, "not playing");
        require(!g.paid, "already paid");
        require(g.raiseActive, "no active raise");
        require(block.timestamp > g.raiseDeadline, "not expired");

        address winner = g.raiser;
        require(winner != address(0), "no raiser");
        address loser = (winner == g.playerX) ? g.playerO : g.playerX;

        g.state = (winner == g.playerX) ? State.WinX : State.WinO;
        g.raiseActive = false;
        g.raiser = address(0);
        g.targetDeposit = 0;
        g.raiseDeadline = 0;
        emit Loss(gameId, loser, winner);
        _payoutWinner(g, winner, gameId);
    }

    // (raise / match / lose removed)

    // Move
    function move(uint256 gameId, uint8 x, uint8 y) external nonReentrant {
        Game storage g = games[gameId];
        require(g.state == State.Playing, "the game is not active");
        require(!g.paid, "already paid");
        require(!g.raiseActive, "raise active");
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

        // If opponent cannot win: current player wins only if they can still win; else draw
        Cell opponentCell = (placed == Cell.X) ? Cell.O : Cell.X;
        if (!canPlayerStillWin(g.board, opponentCell)) {
            if (canPlayerStillWin(g.board, placed)) {
                g.state = (placed == Cell.X) ? State.WinX : State.WinO;
                address winner = (placed == Cell.X) ? g.playerX : g.playerO;
                _payoutWinner(g, winner, gameId);
                return;
            } else {
                g.state = State.Draw;
                _refundDrawWithFee(g, gameId);
                return;
            }
        }

        g.turn = (g.turn == g.playerX) ? g.playerO : g.playerX;
    }

    /// Surrender: treated as draw; both get full refund (no fee)
    function surrender(uint256 gameId) external nonReentrant {
        Game storage g = games[gameId];
        require(g.state == State.Playing, "not playing");
        require(msg.sender == g.playerX || msg.sender == g.playerO, "not player");
        address winner = address(0);
        if (msg.sender == g.playerX) {
            g.state = State.WinO;
            winner = g.playerO;
        } else {
            g.state = State.WinX;
            winner = g.playerX;
        }
        
        emit Surrendered(gameId, msg.sender);
        _payoutWinner(g, winner, gameId);
    }

    /// Timeout: no move within 60s; current turn loses, opponent wins
    function claimTimeout(uint256 gameId) external nonReentrant {
        Game storage g = games[gameId];
        require(g.state == State.Playing, "not playing");
        require(!g.raiseActive, "raise active");
        require(block.timestamp >= g.lastMoveTime + MOVE_TIMEOUT, "not timeout yet");
        address loser = g.turn;
        address winner = (g.turn == g.playerX) ? g.playerO : g.playerX;
        g.state = (g.turn == g.playerX) ? State.WinO : State.WinX;
        emit Timeout(gameId, loser);
        _payoutWinner(g, winner, gameId);
    }

    // Fallback: trigger payout/refund (normal games auto-settle)
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

    function getRaiseInfo(uint256 gameId) external view returns (
        bool raiseActive,
        address raiser,
        uint256 targetDeposit,
        uint256 raiseDeadline,
        uint256 depositX,
        uint256 depositO
    ) {
        Game storage g = games[gameId];
        return (g.raiseActive, g.raiser, g.targetDeposit, g.raiseDeadline, g.depositX, g.depositO);
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
        (bool okO, ) = payable(g.playerO).call{value: b}("");
        require(okO, "refund O failed");
        emit GameEnded(gameId, g.state, address(0), b * 2, 0);
    }

    /// Whether a side can still form a line (any row/col/diag with no opponent piece)
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

