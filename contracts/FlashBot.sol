//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import 'hardhat/console.sol';

import './interfaces/IUniswapV2Pair.sol';
import './libraries/Decimal.sol';
import './libraries/SafeMath.sol';

struct OrderedReserves {
    uint256 a1; // base asset
    uint256 b1;
    uint256 a2;
    uint256 b2;
}

contract FlashBot {
  using Decimal for Decimal.D256;
  using SafeMath for uint256;
  // using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.AddressSet;

  EnumerableSet.AddressSet baseTokens;
  address immutable WETH;

  function baseTokensContains(address token) public view returns (bool) {
      return baseTokens.contains(token);
  }

  constructor(address _WETH) {
      WETH = _WETH;
      baseTokens.add(_WETH);
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