//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import 'hardhat/console.sol';

import './interfaces/IUniswapV2Pair.sol';
import './libraries/Decimal.sol';
import './interfaces/IWETH.sol';
import './libraries/SafeMath.sol';

struct OrderedReserves {
    uint256 a1; // base asset
    uint256 b1;
    uint256 a2;
    uint256 b2;
}

struct ArbitrageInfo {
    address baseToken;
    address quoteToken;
    bool baseTokenSmaller;
    address lowerPool; // pool with lower price, denominated in quote asset
    address higherPool; // pool with higher price, denominated in quote asset
}

struct CallbackData {
    address debtPool;
    address targetPool;
    bool debtTokenSmaller;
    address borrowedToken;
    address debtToken;
    uint256 debtAmount;
    uint256 debtTokenOutAmount;
}

contract FlashBot is Ownable {
  using Decimal for Decimal.D256;
  using SafeMath for uint256;
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.AddressSet;

  EnumerableSet.AddressSet baseTokens;
  address immutable WETH;

  event Withdrawn(address indexed to, uint256 indexed value);
  event BaseTokenAdded(address indexed token);
  event BaseTokenRemoved(address indexed token);

  // ACCESS CONTROL
  // Only the `permissionedPairAddress` may call the `uniswapV2Call` function
  address permissionedPairAddress = address(1);

  function baseTokensContains(address token) public view returns (bool) {
      return baseTokens.contains(token);
  }

  constructor(address _WETH) {
      WETH = _WETH;
      baseTokens.add(_WETH);
  }

  receive() external payable {}

  /// @dev Redirect uniswap callback function
  /// The callback function on different DEX are not same, so use a fallback to redirect to uniswapV2Call
  fallback(bytes calldata _input) external returns (bytes memory) {
      (address sender, uint256 amount0, uint256 amount1, bytes memory data) = abi.decode(_input[4:], (address, uint256, uint256, bytes));
      uniswapV2Call(sender, amount0, amount1, data);
  }

  function withdraw() external {
      uint256 balance = address(this).balance;
      if (balance > 0) {
          payable(owner()).transfer(balance);
          emit Withdrawn(owner(), balance);
      }

      for (uint256 i = 0; i < baseTokens.length(); i++) {
          address token = baseTokens.at(i);
          balance = IERC20(token).balanceOf(address(this));
          if (balance > 0) {
              // do not use safe transfer here to prevents revert by any shitty token
              IERC20(token).transfer(owner(), balance);
          }
      }
  }

  function addBaseToken(address token) external onlyOwner {
      baseTokens.add(token);
      emit BaseTokenAdded(token);
  }

  function removeBaseToken(address token) external onlyOwner {
      uint256 balance = IERC20(token).balanceOf(address(this));
      if (balance > 0) {
          // do not use safe transfer to prevents revert by any shitty token
          IERC20(token).transfer(owner(), balance);
      }
      baseTokens.remove(token);
      emit BaseTokenRemoved(token);
  }

  function getBaseTokens() external view returns (address[] memory tokens) {
      uint256 length = baseTokens.length();
      tokens = new address[](length);
      for (uint256 i = 0; i < length; i++) {
          tokens[i] = baseTokens.at(i);
      }
  }

  // is token0 base token?
  function isbaseTokenSmaller(address pool0, address pool1)
    internal
    view
    returns (
        bool baseSmaller,
        address baseToken,
        address quoteToken
  ){
    require(pool0 != pool1, 'Same pair address');
        (address pool0Token0, address pool0Token1) = (IUniswapV2Pair(pool0).token0(), IUniswapV2Pair(pool0).token1());
        (address pool1Token0, address pool1Token1) = (IUniswapV2Pair(pool1).token0(), IUniswapV2Pair(pool1).token1());
        require(pool0Token0 < pool0Token1 && pool1Token0 < pool1Token1, 'Non standard uniswap AMM pair');
        require(pool0Token0 == pool1Token0 && pool0Token1 == pool1Token1, 'Require same token pair');
        require(baseTokensContains(pool0Token0) || baseTokensContains(pool0Token1), 'No base token in pair');

        (baseSmaller, baseToken, quoteToken) = baseTokensContains(pool0Token0)
            ? (true, pool0Token0, pool0Token1)
            : (false, pool0Token1, pool0Token0);
  }

  // lowerPool is lower quote token price
  function getOrderedReserves(
      address pool0,
      address pool1,
      bool baseTokenSmaller
  )
      internal
      view
      returns (
          address lowerPool,
          address higherPool,
          OrderedReserves memory orderedReserves
      )
  {
    orderedReserves.a1 = 1;
    if (baseTokenSmaller) {
      (orderedReserves.a1, orderedReserves.b1, ) = IUniswapV2Pair(pool0).getReserves();
      (orderedReserves.a2, orderedReserves.b2, ) = IUniswapV2Pair(pool1).getReserves();
    } else {
      (orderedReserves.b1, orderedReserves.a1, ) = IUniswapV2Pair(pool0).getReserves();
      (orderedReserves.b2, orderedReserves.a2, ) = IUniswapV2Pair(pool1).getReserves();
    }
    uint256 b1 = orderedReserves.b1;
    uint256 b2 = orderedReserves.b2;
    Decimal.D256 memory price0 = Decimal.from(orderedReserves.a1).div(b1);
    Decimal.D256 memory price1 = Decimal.from(orderedReserves.a2).div(b2);
    if (price0.lessThan(price1)) {
      lowerPool = pool0;
      higherPool = pool1;
    } else {
      lowerPool = pool1;
      higherPool = pool0;
    }
  }

  function calcSolutionForQuadratic(
      int256 a,
      int256 b,
      int256 c
  ) internal pure returns (int256 x1, int256 x2) {
      int256 m = b**2 - 4 * a * c;
      // m < 0 leads to complex number
      require(m > 0, 'Complex number');

      int256 sqrtM = int256(sqrt(uint256(m)));
      x1 = (-b + sqrtM) / (2 * a);
      x2 = (-b - sqrtM) / (2 * a);
  }
  
  function calcBorrowAmount(OrderedReserves memory reserves)
    internal pure returns (uint256 amount) {
      uint256 min1 = reserves.a1 < reserves.b1 ? reserves.a1 : reserves.b1;
      uint256 min2 = reserves.a2 < reserves.b2 ? reserves.a2 : reserves.b2;
      uint256 min = min1 < min2 ? min1 : min2;

      uint256 d;
      if (min > 1e24) {
          d = 1e20;
      } else if (min > 1e23) {
          d = 1e19;
      } else if (min > 1e22) {
          d = 1e18;
      } else if (min > 1e21) {
          d = 1e17;
      } else if (min > 1e20) {
          d = 1e16;
      } else if (min > 1e19) {
          d = 1e15;
      } else if (min > 1e18) {
          d = 1e14;
      } else if (min > 1e17) {
          d = 1e13;
      } else if (min > 1e16) {
          d = 1e12;
      } else if (min > 1e15) {
          d = 1e11;
      } else {
          d = 1e10;
      }
      (int256 a1, int256 a2, int256 b1, int256 b2) =
            (int256(reserves.a1 / d), int256(reserves.a2 / d), int256(reserves.b1 / d), int256(reserves.b2 / d));

        int256 a = a1 * b1 - a2 * b2;
        int256 b = 2 * b1 * b2 * (a1 + a2);
        int256 c = b1 * b2 * (a1 * b2 - a2 * b1);

        (int256 x1, int256 x2) = calcSolutionForQuadratic(a, b, c);

        // 0 < x < b1 and 0 < x < b2
        require((x1 > 0 && x1 < b1 && x1 < b2) || (x2 > 0 && x2 < b1 && x2 < b2), 'Wrong input order');
        amount = (x1 > 0 && x1 < b1 && x1 < b2) ? uint256(x1) * d : uint256(x2) * d;
  }
  
  function getProfit(address pool0, address pool1)
    external view returns (uint256 profit, address baseToken) {
      // 1. borrow quote token (from higher price pool(base token price))
      // 2. sell quote token (from lower price pool)
      // 3. return base token (from higher price pool, remain some base token)

      // 1. get base token, quote token number from pool0 and pool1
      (bool baseTokenSmaller, , ) = isbaseTokenSmaller(pool0, pool1);
      baseToken = baseTokenSmaller ? IUniswapV2Pair(pool0).token0() : IUniswapV2Pair(pool0).token1();

      (, , OrderedReserves memory orderedReserves) = getOrderedReserves(pool0, pool1, baseTokenSmaller);

      uint256 borrowAmount = calcBorrowAmount(orderedReserves);
      // borrow quote token on lower price pool,
      uint256 debtAmount = getAmountIn(borrowAmount, orderedReserves.a1, orderedReserves.b1);
      // sell borrowed quote token on higher price pool
      uint256 baseTokenOutAmount = getAmountOut(borrowAmount, orderedReserves.b2, orderedReserves.a2);
      // calc profit
      if (baseTokenOutAmount < debtAmount) {
          profit = 0;
      } else {
          profit = baseTokenOutAmount - debtAmount;
      }
  }

  // do arbitrage, deposit profit in this address's balance
  function flashArbitrage(address pool0, address pool1) external {
    ArbitrageInfo memory info;
    (info.baseTokenSmaller, info.baseToken, info.quoteToken) = isbaseTokenSmaller(pool0, pool1);
    OrderedReserves memory orderedReserves;
    (info.lowerPool, info.higherPool, orderedReserves) = getOrderedReserves(pool0, pool1, info.baseTokenSmaller);


    // 1. borrow quote token (from higher price pool(base token price))
    // 2. sell quote token (from lower price pool)
    // 3. return base token (from higher price pool, remain some base token)

    // this must be updated every transaction for callback origin authentication
    permissionedPairAddress = info.lowerPool;

    uint256 balanceBefore = IERC20(info.baseToken).balanceOf(address(this));

    {
      uint256 borrowAmount = calcBorrowAmount(orderedReserves);
      (uint256 amount0Out, uint256 amount1Out) =
          info.baseTokenSmaller ? (uint256(0), borrowAmount) : (borrowAmount, uint256(0));
      uint256 debtAmount = getAmountIn(borrowAmount, orderedReserves.a1, orderedReserves.b1);
      uint256 baseTokenOutAmount = getAmountOut(borrowAmount, orderedReserves.b2, orderedReserves.a2);
      require(baseTokenOutAmount > debtAmount, 'Arbitrage fail, no profit');
      console.log('Profit:', (baseTokenOutAmount - debtAmount) / 1 ether);

      // can only initialize this way to avoid stack too deep error
      CallbackData memory callbackData;
      callbackData.debtPool = info.lowerPool;
      callbackData.targetPool = info.higherPool;
      callbackData.debtTokenSmaller = info.baseTokenSmaller;
      callbackData.borrowedToken = info.quoteToken;
      callbackData.debtToken = info.baseToken;
      callbackData.debtAmount = debtAmount;
      callbackData.debtTokenOutAmount = baseTokenOutAmount;

      bytes memory data = abi.encode(callbackData);
      IUniswapV2Pair(info.lowerPool).swap(amount0Out, amount1Out, address(this), data);
    }

    uint256 balanceAfter = IERC20(info.baseToken).balanceOf(address(this));
    require(balanceAfter > balanceBefore, 'Losing money');

    if (info.baseToken == WETH) {
        IWETH(info.baseToken).withdraw(balanceAfter);
    }
    permissionedPairAddress = address(1);
  }

  function uniswapV2Call(
      address sender,
      uint256 amount0,
      uint256 amount1,
      bytes memory data
  ) public {
    require(permissionedPairAddress == msg.sender);
    require(sender == address(this), 'Not from this contract');
    
    CallbackData memory info = abi.decode(data, (CallbackData));
    // 1. sell amount1 in other pool
    // transfer all quote token
    IERC20(info.borrowedToken).safeTransfer(
      info.targetPool, info.debtTokenSmaller ? amount1 : amount0);
    (uint256 amount0out, uint256 amount1out) = 
      info.debtTokenSmaller ? (info.debtTokenOutAmount, uint256(0)) : (uint256(0), info.debtTokenOutAmount);
    // swap
    IUniswapV2Pair(info.targetPool).swap(amount0out, amount1out, address(this), new bytes(0));
    
    // 2. transfer some base token
    IERC20(info.debtToken).safeTransfer(
      info.debtPool, info.debtAmount);
  }

  function getAmountIn(
      uint256 amountOut,
      uint256 reserveIn,
      uint256 reserveOut
  ) internal pure returns (uint256 amountIn) {
      require(amountOut > 0, 'UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT');
      require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
      uint256 numerator = reserveIn.mul(amountOut).mul(1000);
      uint256 denominator = reserveOut.sub(amountOut).mul(997);
      amountIn = (numerator / denominator).add(1);
  }

  // copy from UniswapV2Library
  // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
  function getAmountOut(
      uint256 amountIn,
      uint256 reserveIn,
      uint256 reserveOut
  ) internal pure returns (uint256 amountOut) {
      require(amountIn > 0, 'UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT');
      require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
      uint256 amountInWithFee = amountIn.mul(997);
      uint256 numerator = amountInWithFee.mul(reserveOut);
      uint256 denominator = reserveIn.mul(1000).add(amountInWithFee);
      amountOut = numerator / denominator;
  }

  function sqrt(uint256 n) internal pure returns (uint256 res) {
      assert(n > 1);

      // The scale factor is a crude way to turn everything into integer calcs.
      // Actually do (n * 10 ^ 4) ^ (1/2)
      uint256 _n = n * 10**6;
      uint256 c = _n;
      res = _n;

      uint256 xi;
      while (true) {
          xi = (res + c / res) / 2;
          // don't need be too precise to save gas
          if (res - xi < 1000) {
              break;
          }
          res = xi;
      }
      res = res / 10**3;
  }
}