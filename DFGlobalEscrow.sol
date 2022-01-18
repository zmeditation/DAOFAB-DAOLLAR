//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DFGlobalEscrow is Ownable {
    enum Sign {
        NULL,
        REVERT,
        RELEASE
    }
    enum TokenType {
        ETH,
        ERC20
    }
    struct EscrowRecord {
        string referenceId;
        address payable delegator;
        address payable owner;
        address payable recipient;
        address payable agent;
        TokenType tokenType;
        address tokenAddress;
        uint256 fund;
        mapping(address => bool) signer;
        mapping(address => Sign) signed;
        uint256 releaseCount;
        uint256 revertCount;
        uint256 lastTxBlock;
        bool funded;
        bool disputed;
        bool finalized;
        bool shouldInvest;
    }

    mapping(string => EscrowRecord) _escrow;
    
    function isSigner(string memory _referenceId, address _signer) public view returns (bool) {
        return _escrow[_referenceId].signer[_signer];
    }
    
    function getSignedAction(string memory _referenceId, address _signer) public view returns (Sign) {
        return _escrow[_referenceId].signed[_signer];
    }
    
    event EscrowInitiated(
        string referenceId,
        address payer,
        uint256 amount,
        address payee,
        address trustedParty,
        uint256 lastBlock
    );
    event Signature(
        string referenceId,
        address signer,
        Sign action,
        uint256 lastBlock
    );
    event Finalized(string referenceId, address winner, uint256 lastBlock);
    event Disputed(string referenceId, address disputer, uint256 lastBlock);
    event Withdrawn(
        string referenceId,
        address payee,
        uint256 amount,
        uint256 lastBlock
    );
    event Funded(
        string indexed referenceId,
        address indexed owner,
        uint256 amount,
        uint256 lastBlock
    );
    
    modifier multisigcheck(string memory _referenceId, address _party) {
        EscrowRecord storage e = _escrow[_referenceId];
        require(!e.finalized, "Escrow should not be finalized");
        require(e.signer[_party], "party should be eligible to sign");
        require(
            e.signed[_party] == Sign.NULL,
            "party should not have signed already"
        );
        _;
        if (e.releaseCount == 2) {
            transferOwnership(e);
        } else if (e.revertCount == 2) {
            finalize(e);
        } else if (e.releaseCount == 1 && e.revertCount == 1) {
            dispute(e, _party);
        }
    }
    modifier onlyEscrowOwner(string memory _referenceId) {
        require(
            _escrow[_referenceId].owner == msg.sender,
            "Sender must be Escrow's owner"
        );
        _;
    }
    modifier onlyEscrowOwnerOrDelegator(string memory _referenceId) {
        require(
            _escrow[_referenceId].owner == msg.sender ||
            _escrow[_referenceId].delegator == msg.sender,
            "Sender must be Escrow's owner or delegator"
        );
        _;
    }
    modifier onlyEscrowPartyOrDelegator(string memory _referenceId) {
        require(
            _escrow[_referenceId].owner == msg.sender ||
            _escrow[_referenceId].recipient == msg.sender ||
            _escrow[_referenceId].agent == msg.sender ||
            _escrow[_referenceId].delegator == msg.sender,
            "Sender must be Escrow's Owner or Recipient or agent or delegator"
        );
        _;
    }
    modifier onlyEscrowOwnerOrRecipientOrDelegator(string memory _referenceId) {
        require(
            _escrow[_referenceId].owner == msg.sender ||
            _escrow[_referenceId].recipient == msg.sender ||
            _escrow[_referenceId].delegator == msg.sender,
            "Sender must be Escrow's Owner or Recipient or delegator"
        );
        _;
    }
    modifier isFunded(string memory _referenceId) {
        require(
            _escrow[_referenceId].funded == true,
            "Escrow should be funded"
        );
        _;
    }
    function createEscrow(
        string memory _referenceId,
        address payable _owner,
        address payable _recipient,
        address payable _agent,
        TokenType tokenType,
        address erc20TokenAddress,
        uint256 tokenAmount
    ) public payable onlyOwner {
        require(msg.sender != address(0), "Sender should not be null");
        require(_owner != address(0), "Recipient should not be null");
        require(_recipient != address(0), "Recipient should not be null");
        require(_agent != address(0), "Trusted Agent should not be null");
        require(_escrow[_referenceId].lastTxBlock == 0, "Duplicate Escrow");
        EscrowRecord storage e = _escrow[_referenceId];
        e.referenceId = _referenceId;
        e.owner = _owner;
        if (!(e.owner == msg.sender)) {
            e.delegator = payable(msg.sender);
        }
        e.recipient = _recipient;
        e.agent = _agent;
        e.tokenType = tokenType;
        e.funded = false;
        if (e.tokenType == TokenType.ETH) {
            e.fund = tokenAmount;
        } else {
            e.tokenAddress = erc20TokenAddress;
            e.fund = tokenAmount;
        }
        e.disputed = false;
        e.finalized = false;
        e.lastTxBlock = block.number;
        e.releaseCount = 0;
        e.revertCount = 0;
        _escrow[_referenceId].signer[_owner] = true;
        _escrow[_referenceId].signer[_recipient] = true;
        _escrow[_referenceId].signer[_agent] = true;
        emit EscrowInitiated(
            _referenceId,
            _owner,
            e.fund,
            _recipient,
            _agent,
            block.number
        );
    }
    function fund(string memory _referenceId, uint256 fundAmount)
        public
        payable
        onlyEscrowOwnerOrDelegator(_referenceId)
    {
        require(
            _escrow[_referenceId].lastTxBlock > 0,
            "Sender should not be null"
        );
        uint256 escrowFund = _escrow[_referenceId].fund;
        EscrowRecord storage e = _escrow[_referenceId];
        if (e.tokenType == TokenType.ETH) {
            require(
            msg.value >= escrowFund,
            "Must fund for exact ETH-amount in Escrow"
        );
        } else {
            require(
            fundAmount == escrowFund,
            "Must fund for exact ERC20-amount in Escrow"
            );
            IERC20 erc20Instance = IERC20(e.tokenAddress);
            erc20Instance.transferFrom(msg.sender, address(this), fundAmount);
        }
        e.funded = true;
        emit Funded(_referenceId, e.owner, escrowFund, block.number);
    }
    function release(string memory _referenceId, address _party)
        public
        multisigcheck(_referenceId, _party)
        onlyEscrowPartyOrDelegator(_referenceId)
    {
        EscrowRecord storage e = _escrow[_referenceId];
        require(
            _party == e.owner || _party == e.recipient || _party == e.agent,
            "Only owner or recipient or agent can reverse an escrow"
        );
        emit Signature(_referenceId, e.owner, Sign.RELEASE, e.lastTxBlock);
        e.signed[e.owner] = Sign.RELEASE;
        e.releaseCount++;
    }
    function reverse(string memory _referenceId, address _party)
        public
        onlyEscrowPartyOrDelegator(_referenceId)
        multisigcheck(_referenceId, _party)
    {
        EscrowRecord storage e = _escrow[_referenceId];
        require(
            _party == e.owner || _party == e.recipient || _party == e.agent,
            "Only owner or recipient or agent can reverse an escrow"
        );
        emit Signature(_referenceId, e.owner, Sign.REVERT, e.lastTxBlock);
        e.signed[e.owner] = Sign.REVERT;
        e.revertCount++;
    }
    function dispute(string memory _referenceId, address _party)
        public
        onlyEscrowOwnerOrRecipientOrDelegator(_referenceId)
    {
        EscrowRecord storage e = _escrow[_referenceId];
        require(!e.finalized, "Cannot dispute on a finalised Escrow");
        require(
            _party == e.owner || _party == e.recipient,
            "Only owner or recipient can dispute on escrow"
        );
        dispute(e, _party);
    }
    function transferOwnership(EscrowRecord storage e) internal {
        e.owner = e.recipient;
        finalize(e);
        e.lastTxBlock = block.number;
    }
    function dispute(EscrowRecord storage e, address _party) internal {
        emit Disputed(e.referenceId, _party, e.lastTxBlock);
        e.disputed = true;
        e.lastTxBlock = block.number;
    }
    function finalize(EscrowRecord storage e) internal {
        require(!e.finalized, "Escrow should not be finalized");
        emit Finalized(e.referenceId, e.owner, e.lastTxBlock);
        e.finalized = true;
    }
    function withdraw(string memory _referenceId, uint256 _amount)
        public
        onlyEscrowOwner(_referenceId)
        isFunded(_referenceId)
    {
        EscrowRecord storage e = _escrow[_referenceId];
        require(e.finalized, "Escrow should be finalized before withdrawal");
        require(_amount <= e.fund, "cannot withdraw more than the deposit");
        address escrowOwner = e.owner;
        emit Withdrawn(_referenceId, escrowOwner, _amount, e.lastTxBlock);
        e.fund = e.fund - _amount;
        e.lastTxBlock = block.number;
        if (e.tokenType == TokenType.ETH) {
            require((e.owner).send(_amount));
        } else {
            IERC20 erc20Instance = IERC20(e.tokenAddress);
            require(erc20Instance.transfer(escrowOwner, _amount));
        }
    }

    function supplyEthToCompound(string memory _referenceId, uint256 _amount)
        public
        payable
        onlyEscrowOwnerOrRecipientOrDelegator(_referenceId)
        returns (bool)
    {
        EscrowRecord storage e = _escrow[_referenceId];
        require(e.finalized, "Escrow should be finalized before withdrawal");
        require(_amount <= e.fund, "cannot withdraw more than the deposit");
        address escrowOwner = e.owner;
                
        // Create a reference to the corresponding cToken contract
        CEth cToken = CEth(escrowOwner);

        // Amount of current exchange rate from cToken to underlying
        uint256 exchangeRate = cToken.exchangeRateCurrent();
        emit MyLog("Exchange Rate (scaled up by 1e18): ", exchangeRate);

        // Amount added to you supply balance this block
        uint256 supplyRate = cToken.supplyRatePerBlock();
        emit MyLog("Supply Rate: (scaled up by 1e18)", supplyRate);

        cToken.mint{ value: _amount, gas: 250000 }();
        return true;
    }

    function redeemCEth(
        string memory _referenceId, 
        uint256 _amount
    ) public onlyEscrowOwnerOrRecipientOrDelegator(_referenceId) returns (bool) {
        EscrowRecord storage e = _escrow[_referenceId];
        require(e.finalized, "Escrow should be finalized before withdrawal");
        address escrowOwner = e.owner;

        // Create a reference to the corresponding cToken contract
        CEth cToken = CEth(escrowOwner);

        uint256 redeemResult = cToken.redeem(_amount);

        // Error codes are listed here:
        emit MyLog("If this is not 0, there was an error", redeemResult);

        return true;
    }
    
    event MyLog(string, uint256);
}

interface CEth {
    function mint() external payable;
    function exchangeRateCurrent() external returns (uint256);
    function supplyRatePerBlock() external returns (uint256);
    function redeem(uint) external returns (uint);
}