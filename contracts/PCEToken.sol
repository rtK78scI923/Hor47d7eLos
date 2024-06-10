// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { SafeMath } from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    ERC20BurnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { PCECommunityToken } from "./PCECommunityToken.sol";
import { Utils } from "./lib/Utils.sol";
import { ExchangeAllowMethod } from "./lib/Enum.sol";
import { NativeMetaTransaction } from "./lib/polygon/NativeMetaTransaction.sol";

contract PCEToken is
    Initializable,
    ERC20Upgradeable,
    OwnableUpgradeable,
    ERC20BurnableUpgradeable,
    NativeMetaTransaction
{
    using SafeMath for uint256;

    // initial rate is 1(NativeToken):5(PCEToken) = 5<<96 = 396140812571321687967719751680
    uint160 public nativeTokenToPceTokenRate = 396140812571321687967719751680;
    uint256 public metaTransactionGas = 200000;
    uint256 public metaTransactionPriorityFee = 50000000000; // 50 gwei

    // Daily swap rate from community token to PCE in basis points
    uint256 public swapableToPCERate = 300; // 300BP is 3%
    // Individual daily swap limit from community token to PCE in basis points
    uint256 public swapableToPCEIndividualRate = 300; // 300BP is 3%

    address private _communityTokenAddress;
    address[] public tokens;
    mapping(address deployedAddress => Utils.LocalToken localToken) public localTokens;

    address public polygonChainManager;

    event TokenCreated(
        address indexed tokenAddress,
        address indexed creator,
        uint256 pcetokenAmount,
        uint256 newTokenAmount
    );
    event TokensSwappedToLocalToken(
        address indexed from,
        address indexed toToken,
        uint256 pceTokenAmount,
        uint256 targetTokenAmount
    );
    event TokensSwappedFromLocalToken(
        address indexed to,
        address indexed fromToken,
        uint256 targetTokenAmount,
        uint256 pceTokenAmount
    );

    uint256 public constant INITIAL_FACTOR = 10 ** 18;
    // 998/1000 = 0.02
    uint256 public constant DECREASE_RATE = 998 * (10 ** 18);
    uint256 public constant DECREASE_RATE_BASE = 1000 * (10 ** 18);

    uint256 public epochTime;
    uint256 public lastDecreaseTime;
    uint256 public lastModifiedFactor;

    function initialize(
        string memory _name,
        string memory _symbol,
        address communityTokenAddress,
        address _polygonChainManager
    ) public initializer {
        __ERC20_init(_name, _symbol);
        __Ownable_init();
        _mint(_msgSender(), 10000 * INITIAL_FACTOR);
        _communityTokenAddress = communityTokenAddress;
        epochTime = block.timestamp;
        lastDecreaseTime = block.timestamp;
        lastModifiedFactor = INITIAL_FACTOR;
        polygonChainManager = _polygonChainManager;
    }

    function getLocalToken(address communityToken) public view returns (Utils.LocalToken memory) {
        return localTokens[communityToken];
    }

    function getCurrentFactor() public view returns (uint256) {
        if (lastModifiedFactor == 0) {
            return 0;
        }
        if (hasDecreaseTimeWithin(lastDecreaseTime, block.timestamp)) {
            return lastModifiedFactor.mul(DECREASE_RATE).div(DECREASE_RATE_BASE);
        } else {
            return lastModifiedFactor;
        }
    }

    function updateFactorIfNeeded() public {
        if (lastDecreaseTime == block.timestamp) {
            return;
        }

        uint256 currentFactor = getCurrentFactor();
        if (currentFactor != lastModifiedFactor) {
            lastModifiedFactor = currentFactor;
            lastDecreaseTime = block.timestamp;
        }
    }

    function transfer(address receiver, uint256 balance) public override returns (bool) {
        updateFactorIfNeeded();
        return super.transfer(receiver, balance);
    }

    function transferFrom(address sender, address receiver, uint256 balance) public override returns (bool) {
        updateFactorIfNeeded();
        return super.transferFrom(sender, receiver, balance);
    }

    function approve(address spender, uint256 balance) public override returns (bool) {
        updateFactorIfNeeded();
        return super.approve(spender, balance);
    }

    function mint(address to, uint256 balance) external {
        updateFactorIfNeeded();
        _mint(to, balance);
    }

    function getTokens() public view returns (address[] memory) {
        return tokens;
    }

    // for DEV
    function faucet() public returns (bool) {
        _mint(msg.sender, 10000 * INITIAL_FACTOR);

        return true;
    }

    function setCommunityTokenAddress(address communityTokenAddress) external onlyOwner {
        _communityTokenAddress = communityTokenAddress;
    }

    function createToken(
        string memory name,
        string memory symbol,
        uint256 amountToExchange,
        uint256 dilutionFactor,
        uint256 decreaseIntervalDays,
        uint16 afterDecreaseBp,
        uint16 maxIncreaseOfTotalSupplyBp,
        uint16 maxIncreaseBp,
        uint16 maxUsageBp,
        uint16 changeBp,
        ExchangeAllowMethod incomeExchangeAllowMethod,
        ExchangeAllowMethod outgoExchangeAllowMethod,
        address[] calldata incomeTargetTokens,
        address[] calldata outgoTargetTokens
    ) public {
        require(amountToExchange > 0, "Amount must be > 0");
        require(balanceOf(_msgSender()) >= amountToExchange, "Insufficient PCEToken bal.");
        require(dilutionFactor >= 10 ** 17 && dilutionFactor <= 10 ** 21, "Dilution factor 0.1-1000");
        require(afterDecreaseBp <= 10000, "After decrease bp <= 10000");

        updateFactorIfNeeded();

        address newTokenAddress = Clones.clone(_communityTokenAddress);
        PCECommunityToken newToken = PCECommunityToken(newTokenAddress);
        newToken.initialize(name, symbol, lastModifiedFactor);
        newToken.setTokenSettings(
            decreaseIntervalDays,
            afterDecreaseBp,
            maxIncreaseOfTotalSupplyBp,
            maxIncreaseBp,
            maxUsageBp,
            changeBp,
            incomeExchangeAllowMethod,
            outgoExchangeAllowMethod,
            incomeTargetTokens,
            outgoTargetTokens
        );

        uint256 newTokenAmount = amountToExchange.mul(dilutionFactor).div(INITIAL_FACTOR);
        _transfer(_msgSender(), address(this), amountToExchange);
        newToken.mint(_msgSender(), newTokenAmount);

        localTokens[newTokenAddress] = Utils.LocalToken(true, dilutionFactor, amountToExchange);
        tokens.push(newTokenAddress);

        newToken.transferOwnership(_msgSender());

        emit TokenCreated(newTokenAddress, _msgSender(), amountToExchange, newTokenAmount);
    }

    function getDepositedPCETokens(address communityToken) public view returns (uint256) {
        require(localTokens[communityToken].isExists, "Target token not found");

        return localTokens[communityToken].depositedPCEToken;
    }

    function getExchangeRate(address communityToken) public view returns (uint256) {
        require(localTokens[communityToken].isExists, "Target token not found");

        return localTokens[communityToken].exchangeRate;
    }

    function getSwapRate(address toToken) public view returns (uint256) {
        require(localTokens[toToken].isExists, "Target token not found");

        PCECommunityToken target = PCECommunityToken(toToken);

        return
            (localTokens[toToken].exchangeRate << 96).div(INITIAL_FACTOR).mul(target.getCurrentFactor()).div(
                lastModifiedFactor
            );
    }

    function swapToLocalToken(address toToken, uint256 amountToSwap) public {
        updateFactorIfNeeded();
        require(localTokens[toToken].isExists, "Target token not found");
        require(balanceOf(_msgSender()) >= amountToSwap, "Not enough PCEToken balance");

        PCECommunityToken target = PCECommunityToken(toToken);
        target.updateFactorIfNeeded();

        uint256 targetTokenAmount = amountToSwap
            .mul(localTokens[toToken].exchangeRate)
            .div(INITIAL_FACTOR)
            .mul(target.getCurrentFactor())
            .div(lastModifiedFactor);
        require(targetTokenAmount > 0, "Invalid amount to swap");

        _transfer(_msgSender(), address(this), amountToSwap);
        target.mint(_msgSender(), targetTokenAmount);

        localTokens[toToken].depositedPCEToken = localTokens[toToken].depositedPCEToken + amountToSwap;

        emit TokensSwappedToLocalToken(_msgSender(), toToken, amountToSwap, targetTokenAmount);
    }

    function swapFromLocalToken(address fromToken, uint256 amountToSwap) public {
        updateFactorIfNeeded();
        require(localTokens[fromToken].isExists, "Target token not found");

        PCECommunityToken target = PCECommunityToken(fromToken);
        target.updateFactorIfNeeded();

        require(target.balanceOf(_msgSender()) >= amountToSwap, "Insufficient balance");

        uint256 pcetokenAmount = amountToSwap
            .mul(INITIAL_FACTOR)
            .div(localTokens[fromToken].exchangeRate)
            .mul(lastModifiedFactor)
            .div(target.getCurrentFactor());
        require(pcetokenAmount > 0, "Target token deposit low");

        require(target.getTodaySwapableToPCEBalance() >= amountToSwap, "Insufficient balance");
        require(target.getTodaySwapableToPCEBalanceForIndividual(_msgSender()) >= amountToSwap, "Insufficient balance");

        target.burnFrom(_msgSender(), amountToSwap);
        _transfer(address(this), _msgSender(), pcetokenAmount);

        localTokens[fromToken].depositedPCEToken = localTokens[fromToken].depositedPCEToken - pcetokenAmount;

        emit TokensSwappedFromLocalToken(_msgSender(), fromToken, amountToSwap, pcetokenAmount);
    }

    /*
        @notice return rate shifted 96bit.
                (NativeToken * rate) >> 96 = PceToken
                (PceToken * ( 1 << 96 ) ) / rate = NativeToken
    */
    function getNativeTokenToPceTokenRate() public view returns (uint256) {
        // TODO: Get the rate dynamically from Oracle or defi such as uniswap.
        return nativeTokenToPceTokenRate;
    }

    function setNativeTokenToPceTokenRate(uint160 _nativeTokenToPceTokenRate) public onlyOwner {
        nativeTokenToPceTokenRate = _nativeTokenToPceTokenRate;
    }

    function setMetaTransactionGas(uint256 _metaTransactionGas) public onlyOwner {
        metaTransactionGas = _metaTransactionGas;
    }

    function setMetaTransactionPriorityFee(uint256 _metaTransactionPriorityFee) public onlyOwner {
        metaTransactionPriorityFee = _metaTransactionPriorityFee;
    }

    function getBlockBaseFee() public view returns (uint256) {
        return block.basefee;
    }

    /*
        @notice Returns the fee in PCE token for the meta transaction in the current block.
    */
    function getMetaTransactionFee() public view returns (uint256) {
        uint256 nativeTokenFee = metaTransactionGas * (block.basefee + metaTransactionPriorityFee);
        return nativeTokenFee.mul(getNativeTokenToPceTokenRate()) >> 96;
    }

    function hasDecreaseTimeWithin(uint _start, uint _end) public pure returns (bool) {
        return getElapsedMinutes(_start, _end) > 1;
        //return isWednesdayBetween(_start, _end);
    }

    function getElapsedMinutes(uint _start, uint _end) public pure returns (uint) {
        require(_start <= _end, "Start time must be <= end");

        uint elapsedSeconds = _end - _start;
        uint elapsedMinutes = elapsedSeconds / 60;

        return elapsedMinutes;
    }

    function isWednesdayBetween(uint start, uint end) public pure returns (bool) {
        require(start <= end, "Start time must be <= end");
        if (start == end) {
            return false;
        }
        uint startDay = start / 1 days;
        uint endDay = end / 1 days;
        if (startDay == endDay) {
            return false;
        }

        // 0 = Thursday, 1 = Friday, 2 = Saturday, ..., 6 = Wednesday
        uint startWeekday = startDay % 7;
        uint endWeekday = endDay % 7;

        if (startWeekday != 6 && startWeekday >= endWeekday) {
            return true;
        } else if (endWeekday == 6) {
            return true;
        } else {
            uint startWeek = startDay / 7;
            uint endWeek = startDay / 7;
            return startWeek != endWeek;
        }
    }

    // for polygon bridge
    function deposit(address user, bytes calldata depositData) external {
        require(msg.sender == polygonChainManager, "Only polygon chain manager can call this function");
        uint256 amount = abi.decode(depositData, (uint256));
        _mint(user, amount);
    }

    function withdraw(uint256 amount) external {
        _burn(_msgSender(), amount);
    }

    function version() public pure returns (string memory) {
        return "1.0.0";
    }
}
