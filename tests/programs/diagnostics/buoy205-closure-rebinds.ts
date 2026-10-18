import { spawn } from "buoy";

class Cart {
  total(prices: number[]): number {
    let sum = 0;
    prices.forEach((price) => {
      sum += price;
    });
    return sum;
  }
}

const cart = spawn(Cart);
console.log(await cart.total([1, 2, 3]));
