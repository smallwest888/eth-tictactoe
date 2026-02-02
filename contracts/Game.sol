// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.4.0
pragma solidity ^0.8.27;

contract Game {
    // 管理者地址，用于收取手续费
    address public immutable manager;
    // 手续费，基点表示（10000 = 100%）
    uint256 public constant managerFeeBps = 250; // 2.5%

    // 简易可重入保护
    bool private locked;
    modifier nonReentrant() {
        require(!locked, "reentrancy");
        locked = true;
        _;
        locked = false;
    }

    enum Cell {
        Empty,
        X, 
        O
    }
    enum State {
        Draw,
        X,
        O,
        WinX,
        WinO
    }
    struct Session {
        bool exists;
        address playerO;
        address playerX;
        uint256 prizePool;
        Cell[3][3] board;
        State turn;
        bool finished;
    }
    mapping(uint256 => Session) public games;
    uint256 gameCount = 0;

    event GameCreated(uint256 indexed gameId, address indexed playerX, uint256 stake);
    event GameJoined(uint256 indexed gameId, address indexed playerO, uint256 matchedStake);
    event GameSettled(uint256 indexed gameId, State outcome, uint256 prizePaid, uint256 managerFee);

    constructor() {
        manager = msg.sender;
    }

    function createGame() external payable returns(uint256) {
        gameCount += 1;
        games[gameCount] = Session({
            exists: true,
            playerO: address(0),
            playerX: msg.sender,
            prizePool: msg.value,
            board: [[Cell.Empty, Cell.Empty, Cell.Empty], [Cell.Empty, Cell.Empty, Cell.Empty], [Cell.Empty, Cell.Empty, Cell.Empty]],
            turn: State.X,
            finished: false
        });
        emit GameCreated(gameCount, msg.sender, msg.value);
        return gameCount;
    }
    function joinGame(uint256 gameId) external payable {
        Session storage game = games[gameId];
        require(game.exists, "no game");
        require(game.playerO == address(0), "already joined");
        require(msg.sender != game.playerX, "playerO must differ");
        require(msg.value == game.prizePool, "stake must match");
        game.prizePool += msg.value;
        game.playerO = msg.sender;
        emit GameJoined(gameId, msg.sender, msg.value);
    }

    // 为演示/培训用途：由管理者（部署者）根据线下裁定结算
    function settleGame(uint256 gameId, State outcome) external nonReentrant {
        Session storage game = games[gameId];
        require(msg.sender == manager, "only manager");
        require(game.exists, "no game");
        require(!game.finished, "settled");
        require(outcome == State.WinX || outcome == State.WinO || outcome == State.Draw, "invalid outcome");
        require(game.playerO != address(0), "game not full");

        uint256 pool = game.prizePool;
        game.prizePool = 0;
        game.finished = true;
        game.turn = outcome;

        uint256 fee = (pool * managerFeeBps) / 10000;
        uint256 remaining = pool - fee;

        if (fee > 0) {
          (bool fm, ) = manager.call{value: fee}("");
          require(fm, "fee transfer failed");
        }

        if (outcome == State.WinX) {
            (bool ok, ) = game.playerX.call{value: remaining}("");
            require(ok, "payout X failed");
            emit GameSettled(gameId, outcome, remaining, fee);
        } else if (outcome == State.WinO) {
            (bool ok, ) = game.playerO.call{value: remaining}("");
            require(ok, "payout O failed");
            emit GameSettled(gameId, outcome, remaining, fee);
        } else {
            uint256 half = remaining / 2;
            (bool ok1, ) = game.playerX.call{value: half}("");
            (bool ok2, ) = game.playerO.call{value: remaining - half}("");
            require(ok1 && ok2, "payout draw failed");
            emit GameSettled(gameId, outcome, remaining, fee);
        }
    }
}
